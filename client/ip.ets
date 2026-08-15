/**
 * 机器狗局域网控狗（手机 / 平板）+ 云端 910 自然语言规划
 *
 * =============================================================================
 * 通信流程概览
 * =============================================================================
 *   1) 点「发现设备」→ UDP 广播 discover（目标端口 9871）
 *   2) 狗机收到后，单播回复 announce（含 ip / port / token）
 *   3) 点「连接」→ TCP 连狗机控制端口 → 发送 hello 做 token 鉴权
 *   4) 鉴权成功后：双虚拟摇杆连续下发 vel；模式键一次性下发 mode
 *      点模式键时前端强制摇杆回中，松手前不再发非零 vel（与狗端门控一致）
 *   5) 「切换到键盘」→ TCP switch，将控制权交给键盘外设后断开手机 TCP
 *   6) 端云与狗机鉴权解耦：可先连狗或先请求 910。
 *      自然语言 → HTTP POST /v1/plan → 校验元动作整单；
 *      已鉴权狗机时按序 mode/vel 下发；未鉴权则仅展示规划结果，不下发。
 *      急停进入保护模式（需已连狗才能真正零速/阻尼）
 *   7) 「语音」→ CoreSpeechKit 麦克风听写，结果写入自然语言框（需 MICROPHONE）
 *   8) 「调试模式」→ 页内显示 910 返回；校验通过后需手动「下发到狗」（不自动执行）
 *
 * 协议细节：
 *   - 报文均为 UTF-8 JSON 文本行，以 '\n' 结尾（TCP 侧按行缓冲解析）
 *   - UDP discover:  {"type":"discover","v":1,"app":"RoboPiPhone"}
 *   - UDP announce:  {"type":"announce","ip":"...","port":N,"token":"...","name":"..."}
 *   - TCP hello:     {"type":"hello","token":"..."}
 *   - TCP hello_ack: {"type":"hello_ack","ok":true/false, ...}
 *   - TCP vel:       {"type":"vel","fwd":f,"side":f,"yaw":f}
 *   - TCP mode:      {"type":"mode","key":"r|z|v|b|j|k"}（云端规划禁止 x 空闲；手动控狗仍可发 x）
 *   - TCP switch:    {"type":"switch","mode":0|1|2|3}  // RemoteCommandType
 *   - NPU plan:      POST {base}/v1/plan  Authorization: Bearer <token>
 *                    body {"v":1,"request_id":"...","text":"..."}
 *                    resp {"v":1,"request_id":"...","ok":true,"actions":[...],"msg":"..."}
 *
 * 权限：module.json5 需声明 ohos.permission.INTERNET（system_grant，安装时自动授权，
 *       勿对 INTERNET 调用 requestPermissionsFromUser，否则会误报拒绝）。
 *       语音识别需 ohos.permission.MICROPHONE（user_grant，点击「语音」时动态申请；
 *       reason 建议 $string:mic_reason）。
 *
 * 坐标系约定（与狗端键盘接口一致）：
 *   fwd  > 0 前进，< 0 后退
 *   side > 0 左移，< 0 右移
 *   yaw  > 0 左转，< 0 右转
 *
 * 切模式安全：点模式 → 摇杆 UI 回中 + 发零速；手指未抬起前忽略拨杆，
 * 双杆均松手后才重新接受速度（狗端同步忽略非零 vel 直至收到全零）。
 *
 * 保护模式：急停后停序列、零速、阻尼 mode=r，锁定摇杆/NL/模式直至用户点「解除保护」。
 *
 * RemoteCommandType（与狗端 types::RemoteCommandType 一致）：
 *   0 = kIdleMode，1 = kKeyBoard，2 = kRetroidGamepad，3 = kOhPhone
 */
import { http, socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';
// 语音：CoreSpeechKit 实时听写；module.json5 须声明 MICROPHONE + mic_reason 字符串资源。

// ---------------------------------------------------------------------------
// 常量：发现 / 控速 / 速度上限
// ---------------------------------------------------------------------------

/** 日志与调试输出前缀 */
const TAG: string = '[DogIpCtrl]';

/** 语音识别会话 id（finish / cancel 时复用） */
const VOICE_SESSION_ID: string = 'dog-nl-voice';

/** 麦克风权限名 */
const PERM_MICROPHONE: Permissions = 'ohos.permission.MICROPHONE';

/** 狗端 UDP 发现服务监听端口；手机向该端口广播 discover */
const UDP_PORT: number = 9871;

/** 单次「发现」流程中，UDP 广播发送的轮数（提高丢包环境下的命中率） */
const DISCOVER_ROUNDS: number = 3;

/** 相邻两轮广播之间的间隔（毫秒） */
const DISCOVER_GAP_MS: number = 400;

/**
 * 广播结束后继续等待 announce 的窗口（毫秒）。
 * 超时后结束「发现中」状态，并提示是否发现设备。
 */
const DISCOVER_WINDOW_MS: number = 2500;

/**
 * 速度指令发送周期（毫秒）。
 * 摇杆有输入时按该频率重复发 vel；回中后停止发送（急停可显式清零）。
 */
const VEL_SEND_MS: number = 100;

/** 前进/后退速度上限（m/s 量级，与狗端缩放一致） */
const MAX_FWD: number = 0.7;

/** 左右平移速度上限 */
const MAX_SIDE: number = 0.5;

/** 左右转向角速度上限 */
const MAX_YAW: number = 0.7;

/** 虚拟摇杆外圈边长（vp） */
const JOYSTICK_SIZE: number = 148;

/** 摇杆帽直径（vp） */
const JOYSTICK_KNOB: number = 52;

/** 摇杆帽最大偏移半径 */
const JOYSTICK_TRAVEL: number = (JOYSTICK_SIZE - JOYSTICK_KNOB) / 2;

/** 摇杆死区（归一化 0~1），小于此幅度视为回中 */
const JOYSTICK_DEADZONE: number = 0.08;

/**
 * 云端 910 规划服务根地址（不含路径）。
 * 联调：填中间机局域网地址，如 http://192.168.1.20:8443（先跑 mid/ssh_tunnel.sh）。
 * 勿填 ModelArts 出口 NAT IP。仅本机调试隧道时可暂用 127.0.0.1。
 */
const NPU_BASE_URL: string = 'http://127.0.0.1:8443';

/** 与 910 服务 NPU_TOKEN / --token 一致 */
const NPU_BEARER_TOKEN: string = 'robotpi';

/** POST /v1/plan 连接与读超时（推理可能较慢，预留余量） */
const NPU_CONNECT_TIMEOUT_MS: number = 15000;
const NPU_READ_TIMEOUT_MS: number = 60000;

/**
 * 云端规划允许的 mode.key（与 910 元操作字典一致）。
 * 不含 x（空闲）：该模式释放关节，规划序列禁止；手动 ModeBtn 仍可单独下发。
 */
const META_MODE_KEYS: string[] = ['r', 'z', 'v', 'b', 'j', 'k'];

/**
 * 控制外设类型（与狗端 types::RemoteCommandType 数值一致）。
 * switch 报文的 mode 字段使用这些常量。
 */
const REMOTE_IDLE: number = 0;             // kIdleMode
const REMOTE_KEYBOARD: number = 1;         // kKeyBoard
const REMOTE_RETROID_GAMEPAD: number = 2;  // kRetroidGamepad
const REMOTE_OH_PHONE: number = 3;         // kOhPhone（本 App）

/**
 * 910 返回的单步元动作（校验通过后才执行）。
 * op=mode 时用 key；op=vel 时用 fwd/side/yaw/duration_ms。
 */
class MetaAction {
  op: string = '';
  key: string = '';
  fwd: number = 0;
  side: number = 0;
  yaw: number = 0;
  duration_ms: number = 0;
}

function remoteCommandLabel(mode: number): string {
  if (mode === REMOTE_KEYBOARD) {
    return '键盘';
  }
  if (mode === REMOTE_RETROID_GAMEPAD) {
    return '手柄';
  }
  if (mode === REMOTE_OH_PHONE) {
    return '手机';
  }
  if (mode === REMOTE_IDLE) {
    return '空闲';
  }
  return `未知(${mode})`;
}

/**
 * 已发现的狗机设备条目。
 * key 用 "ip:port" 去重；token 来自 announce，连接时用于 hello 鉴权。
 */
interface DogDevice {
  /** 列表项唯一键，格式 ip:port */
  key: string;
  /** 设备显示名（announce 的 name，缺省为 RoboPi） */
  name: string;
  /** 狗机局域网 IPv4 */
  ip: string;
  /** 狗机 TCP 控制端口 */
  port: number;
  /** 鉴权令牌，连接后写入 hello */
  token: string;
}

/**
 * 主页面：局域网发现 + TCP 控狗。
 * @Entry 表示可作为 Ability 入口页；@Component 声明为 ArkUI 组件。
 */
@Entry
@Component
struct IpDogCtrl {
  // -------------------------------------------------------------------------
  // UI 绑定状态（@State：变更会触发界面刷新）
  // -------------------------------------------------------------------------

  /** 当前发现到的狗机列表（去重后） */
  @State dogs: DogDevice[] = [];

  /** 底部状态/提示文案 */
  @State logText: string = '同网后点「发现设备」';

  /** 是否正处于 UDP 发现窗口内（禁用重复点击） */
  @State isDiscovering: boolean = false;

  /** TCP 是否已 connect 成功（尚未鉴权也可能为 true） */
  @State isConnected: boolean = false;

  /** hello_ack ok=true 之后才允许发 vel / mode */
  @State isAuthed: boolean = false;

  /** 已连接设备的展示标签，如 "RoboPi 192.168.x.x:port" */
  @State connectedLabel: string = '';

  /** 左摇杆帽相对中心的偏移（vp），驱动 UI */
  @State leftKnobX: number = 0;
  @State leftKnobY: number = 0;

  /** 右摇杆帽相对中心的偏移（vp） */
  @State rightKnobX: number = 0;
  @State rightKnobY: number = 0;

  /**
   * 切模式后门控：摇杆 UI 已回中，忽略拨杆直到双指松手。
   * true 时摇杆帽保持中心，不发非零 vel。
   */
  @State stickVelLocked: boolean = false;

  /** 正在交接控制源，防止连点 */
  @State isSwitchingRemote: boolean = false;

  /**
   * 保护模式：急停后为 true。
   * 期间拒绝摇杆/模式/自然语言下发，直至用户点「解除保护」。
   */
  @State isProtectMode: boolean = false;

  /** 自然语言指令输入框内容 */
  @State nlText: string = '';

  /** 可编辑的 910 服务根地址（默认取 NPU_BASE_URL） */
  @State npuBaseUrl: string = NPU_BASE_URL;

  /** 可编辑的 Bearer token */
  @State npuToken: string = NPU_BEARER_TOKEN;

  /** 正在请求 910 / 回放元动作序列 */
  @State isPlanning: boolean = false;

  /** 序列回放中（与 isPlanning 重叠时用于 UI 提示） */
  @State isPlayingSequence: boolean = false;

  /**
   * 调试模式：页内展示 910 原始返回；校验通过后不自动执行，需点「下发」。
   */
  @State isDebugMode: boolean = false;

  /** 调试区展示的最近一次 910 响应原文 */
  @State debugResponseText: string = '尚未收到 910 返回。发送到 910 后此处显示原始响应。';

  /** 调试模式下是否有已校验、待下发的元动作 */
  @State hasPendingDispatch: boolean = false;

  /** 正在麦克风听写（CoreSpeechKit） */
  @State isVoiceListening: boolean = false;

  // -------------------------------------------------------------------------
  // 非 UI 内部状态（不直接驱动布局）
  // -------------------------------------------------------------------------

  /** 语音识别引擎；听写结束或页面销毁时 shutdown */
  private asrEngine: speechRecognizer.SpeechRecognitionEngine | null = null;

  /** 调试模式缓存的待下发序列（校验已通过） */
  private pendingActions: MetaAction[] | null = null;
  /** UDP Socket：广播 discover、接收 announce；懒创建 */
  private udp: socket.UDPSocket | null = null;

  /** TCP Socket：鉴权与控狗指令 */
  private tcp: socket.TCPSocket | null = null;

  /**
   * TCP 接收缓冲。
   * 网络可能一次推多行或半行，按 '\n' 拆行后再解析 JSON。
   */
  private tcpBuf: string = '';

  /** 当前连接使用的 token（来自所选 DogDevice） */
  private activeToken: string = '';

  /** setInterval 返回的速度发送定时器 id；-1 表示未启动 */
  private velTimerId: number = -1;

  /** 左摇杆：前进速度（上正下负） */
  private holdFwd: number = 0;

  /** 左摇杆：侧移速度（左正右负） */
  private holdSide: number = 0;

  /** 右摇杆：转向速度（左正右负） */
  private holdYaw: number = 0;

  /** 左摇杆是否有手指按住 */
  private leftTouchActive: boolean = false;

  /** 右摇杆是否有手指按住 */
  private rightTouchActive: boolean = false;

  /** 发现窗口结束用的 setTimeout id；-1 表示无 */
  private discoverTimerId: number = -1;

  /** ArrayBuffer → UTF-8 字符串解码器（复用实例） */
  private textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8');

  /**
   * TCP 正在释放中，防止 close/error/主动断开交叉触发重复回收。
   */
  private tcpReleasing: boolean = false;

  /** 绑定到当前 tcp 实例的回调，便于 off 时精确解绑 */
  private onTcpMessageCb: ((info: socket.SocketMessageInfo) => void) | null = null;
  private onTcpCloseCb: (() => void) | null = null;
  private onTcpErrorCb: ((err: BusinessError) => void) | null = null;

  /**
   * 序列回放取消标记：急停/保护时置 true，execute 循环据此中止。
   */
  private sequenceCancel: boolean = false;

  /**
   * 页面即将显示。
   * 不在此处 checkAccessToken / requestPermissions：
   * INTERNET 为 system_grant，声明后安装即生效；错误检查 API 可能导致启动异常。
   */
  aboutToAppear(): void {
    this.log('同网后点「发现设备」；「语音」听写后可发送到 910');
  }

  /** 页面销毁：关闭定时器与 UDP/TCP，避免泄漏 */
  aboutToDisappear(): void {
    this.cleanupAll();
  }

  /**
   * 写控制台日志，并刷新页面底部提示。
   * @param msg 人类可读状态信息
   */
  log(msg: string): void {
    console.info(`${TAG} ${msg}`);
    this.logText = msg;
  }

  /**
   * 将 socket 收到的 ArrayBuffer 解码为字符串。
   * @param buf 原始字节缓冲
   */
  bufferToString(buf: ArrayBuffer): string {
    const bytes = new Uint8Array(buf);
    return this.textDecoder.decodeToString(bytes);
  }

  /**
   * 轻量 JSON 字符串字段提取（不引入完整 JSON.parse，兼容脏行）。
   * 查找 "key":"value" 形式并返回 value；找不到返回空串。
   * @param json 原始行文本
   * @param key  字段名
   */
  extractQuoted(json: string, key: string): string {
    const pat = `"${key}"`;
    const k = json.indexOf(pat);
    if (k < 0) {
      return '';
    }
    const colon = json.indexOf(':', k + pat.length);
    if (colon < 0) {
      return '';
    }
    const q1 = json.indexOf('"', colon + 1);
    if (q1 < 0) {
      return '';
    }
    const q2 = json.indexOf('"', q1 + 1);
    if (q2 < 0) {
      return '';
    }
    return json.substring(q1 + 1, q2);
  }

  /**
   * 轻量 JSON 数字字段提取，查找 "key": <number>。
   * @param json 原始行文本
   * @param key  字段名
   * @returns 解析到的数字；失败返回 NaN
   */
  extractNumber(json: string, key: string): number {
    const pat = `"${key}"`;
    const k = json.indexOf(pat);
    if (k < 0) {
      return NaN;
    }
    const colon = json.indexOf(':', k + pat.length);
    if (colon < 0) {
      return NaN;
    }
    // 跳过冒号后空白
    let i = colon + 1;
    while (i < json.length) {
      const ch = json.charAt(i);
      if (ch !== ' ' && ch !== '\t') {
        break;
      }
      i++;
    }
    // 扫描数字字符（含小数点与正负号）
    let j = i;
    while (j < json.length) {
      const ch = json.charAt(j);
      if ((ch >= '0' && ch <= '9') || ch === '.' || ch === '-' || ch === '+') {
        j++;
      } else {
        break;
      }
    }
    if (j <= i) {
      return NaN;
    }
    return Number(json.substring(i, j));
  }

  /** 生成设备去重键：ip:port */
  makeDogKey(ip: string, port: number): string {
    return `${ip}:${port}`;
  }

  /**
   * 将狗机信息写入/更新发现列表。
   * 同一 ip:port 重复 announce 时覆盖旧条目（刷新 token/name）。
   */
  upsertDog(name: string, ip: string, port: number, token: string): void {
    const key = this.makeDogKey(ip, port);
    const next: DogDevice = {
      key: key,
      name: name.length > 0 ? name : 'RoboPi',
      ip: ip,
      port: port,
      token: token
    };
    // 不可变更新：生成新数组赋给 @State，确保 List 刷新
    const list: DogDevice[] = [];
    let replaced = false;
    for (let i = 0; i < this.dogs.length; i++) {
      if (this.dogs[i].key === key) {
        list.push(next);
        replaced = true;
      } else {
        list.push(this.dogs[i]);
      }
    }
    if (!replaced) {
      list.push(next);
    }
    this.dogs = list;
  }

  /**
   * 处理一行 UDP 文本：仅接受 type=announce 的宣告。
   * 其它类型或字段不全则忽略。
   */
  handleAnnounceLine(line: string): void {
    if (line.length === 0) {
      return;
    }
    const type = this.extractQuoted(line, 'type');
    if (type !== 'announce') {
      return;
    }
    const ip = this.extractQuoted(line, 'ip');
    const name = this.extractQuoted(line, 'name');
    const token = this.extractQuoted(line, 'token');
    const port = this.extractNumber(line, 'port');
    if (ip.length === 0 || !(port > 0)) {
      return;
    }
    this.upsertDog(name, ip, port, token);
    this.log(`发现: ${name.length > 0 ? name : 'RoboPi'} ${ip}:${port}`);
  }

  /**
   * 懒创建并绑定 UDP Socket。
   * - bind 0.0.0.0:0：系统分配本地端口，用于收狗机单播回复
   * - broadcast=true：允许向 255.255.255.255 发发现包
   * - message 回调：按行解析 announce
   */
  async ensureUdp(): Promise<socket.UDPSocket> {
    if (this.udp !== null) {
      return this.udp;
    }
    const udp = socket.constructUDPSocketInstance();
    const bindAddr: socket.NetAddress = {
      address: '0.0.0.0',
      port: 0,       // 0 = 系统随机可用端口
      family: 1      // 1 = IPv4
    };
    await udp.bind(bindAddr);
    const extra: socket.UDPExtraOptions = {
      broadcast: true,
      reuseAddress: true
    };
    await udp.setExtraOptions(extra);

    // 狗机可能一次回复多行；按 '\n' 切开逐行处理
    // 这里是在注册回调函数
    udp.on('message', (info: socket.SocketMessageInfo) => {
      const text = this.bufferToString(info.message);
      const parts = text.split('\n');
      for (let i = 0; i < parts.length; i++) {
        let line = parts[i];
        // 去掉行尾 \r 与尾部空格
        while (line.endsWith('\r') || line.endsWith(' ')) {
          line = line.substring(0, line.length - 1);
        }
        this.handleAnnounceLine(line);
      }
    });
    udp.on('error', (err: BusinessError) => {
      this.log(`UDP 错误: ${err.code} ${err.message}`);
    });

    this.udp = udp;
    return udp;
  }

  /**
   * 向局域网广播一次 discover。
   * 目标 255.255.255.255:UDP_PORT；狗端 OhPhone 监听后回 announce。
   */
  async broadcastDiscoverOnce(): Promise<void> {
    const udp = await this.ensureUdp();
    const dest: socket.NetAddress = {
      address: '255.255.255.255',
      port: UDP_PORT,
      family: 1
    };
    const options: socket.UDPSendOptions = {
      data: '{"type":"discover","v":1,"app":"RoboPiPhone"}\n',
      address: dest
    };
    await udp.send(options);
  }

  /**
   * 开始一次完整发现流程：
   * 1) 清空列表并标记 isDiscovering
   * 2) 连续 DISCOVER_ROUNDS 次广播，间隔 DISCOVER_GAP_MS
   * 3) 再等待 DISCOVER_WINDOW_MS 收集 announce，然后结束发现
   */
  async startDiscover(): Promise<void> {
    if (this.isDiscovering) {
      return;
    }
    this.isDiscovering = true;
    this.dogs = [];
    this.log('正在局域网广播发现...');

    try {
      await this.ensureUdp();
      for (let i = 0; i < DISCOVER_ROUNDS; i++) {
        await this.broadcastDiscoverOnce();
        if (i + 1 < DISCOVER_ROUNDS) {
          await this.sleep(DISCOVER_GAP_MS);
        }
      }
    } catch (err) {
      const e = err as BusinessError;
      this.log(`发现失败: ${e.code} ${e.message}`);
      this.isDiscovering = false;
      return;
    }

    // 取消上一次未完成的发现窗口定时器
    if (this.discoverTimerId >= 0) {
      clearTimeout(this.discoverTimerId);
    }
    this.discoverTimerId = setTimeout(() => {
      this.isDiscovering = false;
      this.discoverTimerId = -1;
      if (this.dogs.length === 0) {
        this.log('未发现设备：确认同网、狗端已启动 OhPhone');
      } else {
        this.log(`发现结束，共 ${this.dogs.length} 台`);
      }
    }, DISCOVER_WINDOW_MS);
  }

  /** Promise 版延时，供 async 发现循环使用 */
  sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /**
   * 对指定狗机建立 TCP 连接并发送 hello。
   * 若已有连接，先断开再连新设备。
   * 成功后等待 hello_ack；鉴权通过后由 handleTcpLine 启动速度环。
   */
  async connectDog(dog: DogDevice): Promise<void> {
    if (this.isConnected || this.tcp !== null) {
      await this.disconnectTcp(true);
    }
    this.log(`连接 ${dog.name} ${dog.ip}:${dog.port} ...`);
    this.activeToken = dog.token;
    this.tcpBuf = '';

    const tcp = socket.constructTCPSocketInstance();

    // 先挂回调再 connect，避免对端极快断开时丢事件；保存引用以便释放时 off
    this.onTcpMessageCb = (info: socket.SocketMessageInfo) => {
      this.onTcpMessage(info.message);
    };
    this.onTcpCloseCb = () => {
      this.onTcpClosed('对端关闭');
    };
    this.onTcpErrorCb = (err: BusinessError) => {
      this.log(`TCP 错误: ${err.code} ${err.message}`);
      this.onTcpClosed('TCP 错误');
    };
    tcp.on('message', this.onTcpMessageCb);
    tcp.on('close', this.onTcpCloseCb);
    tcp.on('error', this.onTcpErrorCb);

    const addr: socket.NetAddress = {
      address: dog.ip,
      port: dog.port,
      family: 1
    };
    const connectOpt: socket.TCPConnectOptions = {
      address: addr,
      timeout: 5000  // 连接超时 5 秒
    };

    try {
      await tcp.connect(connectOpt);
      // 控狗要求低延迟：关闭 Nagle；keepAlive 便于检测断线
      const extra: socket.TCPExtraOptions = {
        TCPNoDelay: true,
        keepAlive: true
      };
      await tcp.setExtraOptions(extra);
      this.tcp = tcp;
      this.isConnected = true;
      this.isAuthed = false;
      this.connectedLabel = `${dog.name} ${dog.ip}:${dog.port}`;
      // 携带 announce 下发的 token 做鉴权
      await this.sendTcpLine(`{"type":"hello","token":"${dog.token}"}`);
      this.log('已连接，等待鉴权...');
    } catch (err) {
      const e = err as BusinessError;
      this.log(`连接失败: ${e.code} ${e.message}`);
      await this.disposeTcpSocket(tcp);
      this.resetConnectionUiState();
    }
  }

  /**
   * TCP 原始数据到达：拼接到 tcpBuf，按 '\n' 拆行交给 handleTcpLine。
   * 支持粘包（一次多行）与半包（一行分多次到达）。
   */
  onTcpMessage(buf: ArrayBuffer): void {
    this.tcpBuf += this.bufferToString(buf);
    let pos = this.tcpBuf.indexOf('\n');
    while (pos >= 0) {
      let line = this.tcpBuf.substring(0, pos);
      this.tcpBuf = this.tcpBuf.substring(pos + 1);
      while (line.endsWith('\r') || line.endsWith(' ')) {
        line = line.substring(0, line.length - 1);
      }
      this.handleTcpLine(line);
      pos = this.tcpBuf.indexOf('\n');
    }
  }

  /**
   * 处理狗端下发的一行 TCP JSON：
   * - hello_ack：鉴权结果；成功则 startVelLoop
   * - pong：心跳应答，忽略
   * - err：显示狗端错误信息
   */
  handleTcpLine(line: string): void {
    if (line.length === 0) {
      return;
    }
    const type = this.extractQuoted(line, 'type');
    if (type === 'hello_ack') {
      // 简单判断 ok 字段为 true（与狗端约定格式一致）
      const okIdx = line.indexOf('"ok":true');
      if (okIdx >= 0) {
        this.isAuthed = true;
        this.log('鉴权成功，可以控狗');
        this.startVelLoop();
      } else {
        this.isAuthed = false;
        this.log('鉴权失败：token 不匹配');
      }
      return;
    }
    if (type === 'pong') {
      return;
    }
    if (type === 'err') {
      const msg = this.extractQuoted(line, 'msg');
      this.log(`狗端错误: ${msg}`);
      return;
    }
  }

  /**
   * 复位与连接相关的 UI / 控制状态（不碰 socket 本身）。
   */
  private resetConnectionUiState(): void {
    this.isConnected = false;
    this.isAuthed = false;
    this.connectedLabel = '';
    this.activeToken = '';
    this.tcpBuf = '';
    this.leftTouchActive = false;
    this.rightTouchActive = false;
    this.stickVelLocked = false;
    this.isSwitchingRemote = false;
    this.leftKnobX = 0;
    this.leftKnobY = 0;
    this.rightKnobX = 0;
    this.rightKnobY = 0;
    this.holdFwd = 0;
    this.holdSide = 0;
    this.holdYaw = 0;
  }

  /**
   * 解绑回调并关闭给定 TCP socket（不依赖 this.tcp，避免竞态）。
   */
  private async disposeTcpSocket(tcp: socket.TCPSocket | null): Promise<void> {
    if (tcp === null) {
      return;
    }
    try {
      if (this.onTcpMessageCb !== null) {
        tcp.off('message', this.onTcpMessageCb);
      } else {
        tcp.off('message');
      }
      if (this.onTcpCloseCb !== null) {
        tcp.off('close', this.onTcpCloseCb);
      } else {
        tcp.off('close');
      }
      if (this.onTcpErrorCb !== null) {
        tcp.off('error', this.onTcpErrorCb);
      } else {
        tcp.off('error');
      }
    } catch (_) {
      // ignore：部分平台 off 在已关闭 socket 上可能抛错
    }
    this.onTcpMessageCb = null;
    this.onTcpCloseCb = null;
    this.onTcpErrorCb = null;
    try {
      await tcp.close();
    } catch (_) {
      // ignore
    }
  }

  /**
   * 统一回收 TCP 连接资源（对端断开 / 出错 / 主动断开 / 发送失败共用）。
   * @param reason 状态栏提示
   * @param silent 为 true 时不覆盖 logText（切换控制源等场景）
   */
  private async releaseTcpConnection(reason: string, silent: boolean = false): Promise<void> {
    if (this.tcpReleasing) {
      return;
    }
    this.tcpReleasing = true;
    try {
      this.stopVelLoop();
      const tcp = this.tcp;
      this.tcp = null;
      await this.disposeTcpSocket(tcp);
      this.resetConnectionUiState();
      if (!silent) {
        this.log(`已断开: ${reason}`);
      }
    } finally {
      this.tcpReleasing = false;
    }
  }

  /**
   * TCP 被动断开（对端关闭 / 错误）时的统一清理。
   * 停止速度环、off 监听、close socket，并重置 UI。
   */
  onTcpClosed(reason: string): void {
    // 异步回收；不 await，避免阻塞 socket 回调线程
    this.releaseTcpConnection(reason, false).catch((err: BusinessError) => {
      console.error(`${TAG} releaseTcpConnection failed: ${err.code} ${err.message}`);
    });
  }

  /**
   * 用户主动断开 TCP：先停速度环，再 close socket，重置 UI 状态。
   */
  async disconnectTcp(silent: boolean = false): Promise<void> {
    await this.releaseTcpConnection(silent ? '主动断开' : '用户断开', silent);
  }

  /**
   * 发送一行 JSON（自动补 '\n'）。未连接时静默返回。
   * 发送失败视为链路失效，触发资源回收。
   * @param line 不含末尾换行的 JSON 文本
   */
  async sendTcpLine(line: string): Promise<void> {
    if (this.tcp === null || this.tcpReleasing) {
      return;
    }
    const options: socket.TCPSendOptions = {
      data: `${line}\n`
    };
    try {
      await this.tcp.send(options);
    } catch (err) {
      const e = err as BusinessError;
      this.log(`发送失败: ${e.code} ${e.message}`);
      await this.releaseTcpConnection('发送失败，对端可能已断开', false);
      // ArkTS 仅允许 throw Error，不能 throw 任意 catch 值
      throw new Error(`TCP send failed: ${e.code} ${e.message}`);
    }
  }

  /** 速度数值格式化为固定小数，避免 JSON 出现超长浮点串 */
  private formatVel(v: number): string {
    return v.toFixed(4);
  }

  private velPayload(): string {
    return `{"type":"vel","fwd":${this.formatVel(this.holdFwd)},"side":${this.formatVel(this.holdSide)},"yaw":${this.formatVel(this.holdYaw)}}`;
  }

  /**
   * 启动速度发送循环：每 VEL_SEND_MS 若三轴有非零，则发 vel。
   * 全零时不发包，减少空闲流量；急停按钮可主动发一次零速度。
   */
  startVelLoop(): void {
    this.stopVelLoop();
    this.velTimerId = setInterval(() => {
      if (!this.isAuthed || this.tcp === null || this.tcpReleasing) {
        return;
      }
      if (this.isProtectMode) {
        return;
      }
      if (this.holdFwd === 0 && this.holdSide === 0 && this.holdYaw === 0) {
        return;
      }
      this.sendTcpLine(this.velPayload()).catch((err: BusinessError) => {
        // sendTcpLine 内部已触发 release；此处仅兜底日志
        console.warn(`${TAG} vel send failed: ${err.code}`);
      });
    }, VEL_SEND_MS);
  }

  /** 停止速度发送定时器 */
  stopVelLoop(): void {
    if (this.velTimerId >= 0) {
      clearInterval(this.velTimerId);
      this.velTimerId = -1;
    }
  }

  /** 将偏移限制在摇杆行程圆内 */
  private clampToCircle(dx: number, dy: number, maxR: number): [number, number] {
    const len = Math.sqrt(dx * dx + dy * dy);
    if (len > maxR && len > 1e-6) {
      return [dx * maxR / len, dy * maxR / len];
    }
    return [dx, dy];
  }

  /**
   * 屏幕偏移 → 死区处理后的归一化轴值 [-1, 1]。
   * 屏幕坐标：x 右正、y 下正。
   */
  private normalizeAxis(dx: number, dy: number): [number, number] {
    const nx = dx / JOYSTICK_TRAVEL;
    const ny = dy / JOYSTICK_TRAVEL;
    const mag = Math.sqrt(nx * nx + ny * ny);
    if (mag < JOYSTICK_DEADZONE) {
      return [0, 0];
    }
    const scale = (mag - JOYSTICK_DEADZONE) / (1 - JOYSTICK_DEADZONE);
    return [nx / mag * scale, ny / mag * scale];
  }

  /**
   * 左摇杆：前后 + 左右平移（对齐手柄左摇杆）。
   * 上 → fwd+，左 → side+。
   * 切模式锁定期间不更新位置与速度（UI 保持回中）。
   */
  private applyLeftStick(dx: number, dy: number): void {
    // 保护模式或序列回放中：忽略人工拨杆
    if (this.isProtectMode || this.isPlayingSequence) {
      this.leftKnobX = 0;
      this.leftKnobY = 0;
      this.holdFwd = 0;
      this.holdSide = 0;
      return;
    }
    if (this.stickVelLocked) {
      this.leftKnobX = 0;
      this.leftKnobY = 0;
      this.holdFwd = 0;
      this.holdSide = 0;
      return;
    }
    const clamped = this.clampToCircle(dx, dy, JOYSTICK_TRAVEL);
    this.leftKnobX = clamped[0];
    this.leftKnobY = clamped[1];
    const axes = this.normalizeAxis(clamped[0], clamped[1]);
    this.holdFwd = -axes[1] * MAX_FWD;
    this.holdSide = -axes[0] * MAX_SIDE;
  }

  /**
   * 右摇杆：转向（对齐手柄右摇杆 X）。
   * 左 → yaw+，右 → yaw-；Y 仅做视觉跟随。
   * 切模式锁定期间不更新位置与速度（UI 保持回中）。
   */
  private applyRightStick(dx: number, dy: number): void {
    if (this.isProtectMode || this.isPlayingSequence) {
      this.rightKnobX = 0;
      this.rightKnobY = 0;
      this.holdYaw = 0;
      return;
    }
    if (this.stickVelLocked) {
      this.rightKnobX = 0;
      this.rightKnobY = 0;
      this.holdYaw = 0;
      return;
    }
    const clamped = this.clampToCircle(dx, dy, JOYSTICK_TRAVEL);
    this.rightKnobX = clamped[0];
    this.rightKnobY = clamped[1];
    const axes = this.normalizeAxis(clamped[0], clamped[1]);
    this.holdYaw = -axes[0] * MAX_YAW;
  }

  /** 立即按当前 hold 发一帧 vel（松手回中 / 急停 / 切模式用） */
  private pushVelNow(): void {
    if (!this.isAuthed || this.tcp === null || this.tcpReleasing) {
      return;
    }
    this.sendTcpLine(this.velPayload()).catch((err: BusinessError) => {
      console.warn(`${TAG} pushVel send failed: ${err.code}`);
    });
  }

  /**
   * 双指均已抬起则解除切模式锁定，允许再次拨杆。
   * @param announce 是否写状态栏提示（切模式时无指立即解锁不提示）
   */
  private tryUnlockStickGate(announce: boolean = true): void {
    if (this.stickVelLocked && !this.leftTouchActive && !this.rightTouchActive) {
      this.stickVelLocked = false;
      if (announce) {
        this.log('摇杆已回中，可继续控速');
      }
    }
  }

  /**
   * 点击模式：强制双杆 UI 回中、清零速度、发零速，并锁定直到双指松手。
   * 若当前无手指按住，立即解锁（已视为回中）。
   */
  private engageModeStickGate(): void {
    this.leftKnobX = 0;
    this.leftKnobY = 0;
    this.rightKnobX = 0;
    this.rightKnobY = 0;
    this.holdFwd = 0;
    this.holdSide = 0;
    this.holdYaw = 0;
    this.pushVelNow();
    this.stickVelLocked = true;
    this.tryUnlockStickGate(false);
    if (this.stickVelLocked) {
      this.log('模式已切换，请松手回中后再拨杆');
    }
  }

  /** 左摇杆回中（不影响转向） */
  private resetLeftStick(): void {
    this.leftKnobX = 0;
    this.leftKnobY = 0;
    this.holdFwd = 0;
    this.holdSide = 0;
    this.pushVelNow();
    this.tryUnlockStickGate();
  }

  /** 右摇杆回中（不影响平移） */
  private resetRightStick(): void {
    this.rightKnobX = 0;
    this.rightKnobY = 0;
    this.holdYaw = 0;
    this.pushVelNow();
    this.tryUnlockStickGate();
  }

  /**
   * 急停：进入保护模式。
   * - 取消元动作序列回放
   * - 双杆回中并立即发零速度
   * - 若已鉴权则切阻尼 mode=r
   * - 锁定摇杆 / 模式键 / 自然语言，直至解除保护
   */
  private emergencyStop(): void {
    this.sequenceCancel = true;
    this.isPlayingSequence = false;
    this.stopVoiceRecognition(false);
    this.leftKnobX = 0;
    this.leftKnobY = 0;
    this.rightKnobX = 0;
    this.rightKnobY = 0;
    this.holdFwd = 0;
    this.holdSide = 0;
    this.holdYaw = 0;
    this.leftTouchActive = false;
    this.rightTouchActive = false;
    this.stickVelLocked = false;
    this.pushVelNow();
    this.isProtectMode = true;
    if (this.isAuthed) {
      // 阻尼：与任务文档保护模式最低要求一致（关节进入阻尼，非锁死）
      this.sendTcpLine('{"type":"mode","key":"r"}').catch((err: BusinessError) => {
        console.warn(`${TAG} protect mode r failed: ${err.code}`);
      });
    }
    this.log('保护模式：已零速+阻尼，点「解除保护」后才能继续控制');
  }

  /** 用户确认安全后退出保护模式 */
  private clearProtectMode(): void {
    if (!this.isProtectMode) {
      return;
    }
    this.isProtectMode = false;
    this.sequenceCancel = false;
    this.log('已解除保护，可继续控狗 / 发送自然语言');
  }

  /** Promise 版延时，供序列回放使用 */
  private sleepMs(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 速度钳位到手机端上限，超限打日志 */
  private clampVelAxis(v: number, maxAbs: number, name: string): number {
    if (v > maxAbs) {
      this.log(`速度${name} ${v.toFixed(3)} > ${maxAbs}，已钳位`);
      return maxAbs;
    }
    if (v < -maxAbs) {
      this.log(`速度${name} ${v.toFixed(3)} < ${-maxAbs}，已钳位`);
      return -maxAbs;
    }
    return v;
  }

  private isValidModeKey(key: string): boolean {
    for (let i = 0; i < META_MODE_KEYS.length; i++) {
      if (META_MODE_KEYS[i] === key) {
        return true;
      }
    }
    return false;
  }

  /**
   * 整单校验元动作；任一非法返回错误文案，合法返回空串。
   * 不做「过滤后执行」——与任务文档一致。
   */
  private validateMetaActions(actions: MetaAction[]): string {
    if (actions.length === 0) {
      return 'actions 为空';
    }
    for (let i = 0; i < actions.length; i++) {
      const a = actions[i];
      if (a.op === 'mode') {
        if (!this.isValidModeKey(a.key)) {
          return `第${i + 1}步非法 mode.key=${a.key}`;
        }
      } else if (a.op === 'vel') {
        if (!(a.duration_ms > 0) || Math.floor(a.duration_ms) !== a.duration_ms) {
          return `第${i + 1}步 vel.duration_ms 非法: ${a.duration_ms}`;
        }
        if (!isFinite(a.fwd) || !isFinite(a.side) || !isFinite(a.yaw)) {
          return `第${i + 1}步 vel 速度非有限数`;
        }
      } else {
        return `第${i + 1}步未知 op=${a.op}`;
      }
    }
    return '';
  }

  /**
   * 从 910 响应 JSON 中解析 actions 数组。
   * 使用轻量扫描，避免复杂依赖；字段缺省按 0 / 空串。
   */
  private parseActionsFromResponse(body: string): MetaAction[] | null {
    const idx = body.indexOf('"actions"');
    if (idx < 0) {
      return null;
    }
    const lb = body.indexOf('[', idx);
    if (lb < 0) {
      return null;
    }
    let depth = 0;
    let rb = -1;
    for (let i = lb; i < body.length; i++) {
      const ch = body.charAt(i);
      if (ch === '[') {
        depth++;
      } else if (ch === ']') {
        depth--;
        if (depth === 0) {
          rb = i;
          break;
        }
      }
    }
    if (rb < 0) {
      return null;
    }
    const arrText = body.substring(lb + 1, rb);
    const actions: MetaAction[] = [];
    // 按顶层 {...} 切分对象
    let i = 0;
    while (i < arrText.length) {
      const start = arrText.indexOf('{', i);
      if (start < 0) {
        break;
      }
      let d = 0;
      let end = -1;
      for (let j = start; j < arrText.length; j++) {
        const c = arrText.charAt(j);
        if (c === '{') {
          d++;
        } else if (c === '}') {
          d--;
          if (d === 0) {
            end = j;
            break;
          }
        }
      }
      if (end < 0) {
        break;
      }
      const obj = arrText.substring(start, end + 1);
      const a = new MetaAction();
      a.op = this.extractQuoted(obj, 'op');
      a.key = this.extractQuoted(obj, 'key');
      const fwdS = this.extractNumber(obj, 'fwd');
      const sideS = this.extractNumber(obj, 'side');
      const yawS = this.extractNumber(obj, 'yaw');
      const durS = this.extractNumber(obj, 'duration_ms');
      a.fwd = isNaN(fwdS) ? 0 : fwdS;
      a.side = isNaN(sideS) ? 0 : sideS;
      a.yaw = isNaN(yawS) ? 0 : yawS;
      a.duration_ms = isNaN(durS) ? 0 : Math.floor(durS);
      actions.push(a);
      i = end + 1;
    }
    return actions;
  }

  /**
   * 按文档回放单步 vel：周期发速度，到期发零速。
   * 保护/取消时立即停。
   */
  private async playVelStep(a: MetaAction): Promise<void> {
    const fwd = this.clampVelAxis(a.fwd, MAX_FWD, 'fwd');
    const side = this.clampVelAxis(a.side, MAX_SIDE, 'side');
    const yaw = this.clampVelAxis(a.yaw, MAX_YAW, 'yaw');
    this.log(`序列 vel fwd=${fwd.toFixed(2)} side=${side.toFixed(2)} yaw=${yaw.toFixed(2)} ${a.duration_ms}ms`);
    const endAt = Date.now() + a.duration_ms;
    while (Date.now() < endAt) {
      if (this.sequenceCancel || this.isProtectMode || !this.isAuthed) {
        break;
      }
      this.holdFwd = fwd;
      this.holdSide = side;
      this.holdYaw = yaw;
      this.pushVelNow();
      await this.sleepMs(VEL_SEND_MS);
    }
    this.holdFwd = 0;
    this.holdSide = 0;
    this.holdYaw = 0;
    this.pushVelNow();
  }

  /** 按序执行已校验的元动作序列 */
  private async executeMetaActions(actions: MetaAction[]): Promise<void> {
    this.sequenceCancel = false;
    this.isPlayingSequence = true;
    this.stickVelLocked = true;
    this.leftKnobX = 0;
    this.leftKnobY = 0;
    this.rightKnobX = 0;
    this.rightKnobY = 0;
    try {
      for (let i = 0; i < actions.length; i++) {
        if (this.sequenceCancel || this.isProtectMode) {
          this.log(`序列已中止（保护/急停），停在第${i + 1}步前`);
          break;
        }
        if (!this.isAuthed) {
          this.log('狗机未鉴权，中止序列');
          break;
        }
        const a = actions[i];
        if (a.op === 'mode') {
          this.log(`序列 mode=${a.key} (${i + 1}/${actions.length})`);
          // 直接发 mode，避免 engageModeStickGate 干扰序列速度
          try {
            await this.sendTcpLine(`{"type":"mode","key":"${a.key}"}`);
            await this.sleepMs(200);
          } catch (_) {
            this.log('序列 mode 发送失败');
            break;
          }
        } else if (a.op === 'vel') {
          await this.playVelStep(a);
        }
      }
      if (!this.sequenceCancel && !this.isProtectMode) {
        this.log('元动作序列执行完成');
      }
    } finally {
      this.holdFwd = 0;
      this.holdSide = 0;
      this.holdYaw = 0;
      this.pushVelNow();
      this.isPlayingSequence = false;
      this.stickVelLocked = false;
    }
  }

  /** 切换调试模式：开则显示页内返回区；关则清空待下发缓存 */
  private toggleDebugMode(): void {
    this.isDebugMode = !this.isDebugMode;
    if (!this.isDebugMode) {
      this.clearPendingDispatch();
      this.log('已退出调试模式');
    } else {
      this.log('已进入调试模式：返回值显示在下方，校验通过后需手动「下发」');
    }
  }

  private clearPendingDispatch(): void {
    this.pendingActions = null;
    this.hasPendingDispatch = false;
  }

  /** 记录 910 原始返回到调试展示区（始终更新文案，便于随后打开调试也能看到） */
  private recordDebugResponse(httpCode: number, body: string): void {
    const clipped = body.length > 8000 ? `${body.substring(0, 8000)}\n…(已截断)` : body;
    this.debugResponseText = `HTTP ${httpCode}\n────\n${clipped}`;
  }

  /**
   * 向 910 请求规划并在本地校验。
   * 普通模式：已鉴权则自动下发；调试模式：只缓存，等用户点「下发」。
   */
  async submitNaturalCommand(): Promise<void> {
    const text = this.nlText.trim();
    if (text.length === 0) {
      this.log('请先输入自然语言指令');
      return;
    }
    if (this.isProtectMode) {
      this.log('保护模式中，请先解除保护');
      return;
    }
    if (this.isPlanning || this.isPlayingSequence) {
      this.log('正在规划或执行中，请稍候');
      return;
    }

    let base = this.npuBaseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.length === 0) {
      this.log('请填写 910 服务地址');
      return;
    }

    this.clearPendingDispatch();
    this.isPlanning = true;
    const requestId = `req-${Date.now()}`;
    const url = `${base}/v1/plan`;
    const body =
      `{"v":1,"request_id":"${requestId}","text":"${text.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"}`;
    this.log(`请求 910 规划: ${url}${this.isDebugMode ? '（调试·不自动下发）' :
      (this.isAuthed ? '' : '（未连狗，仅规划）')}`);

    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${this.npuToken.trim()}`
        },
        extraData: body,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: NPU_CONNECT_TIMEOUT_MS,
        readTimeout: NPU_READ_TIMEOUT_MS
      });
      const code = resp.responseCode;
      const resultStr: string = typeof resp.result === 'string' ? resp.result : `${resp.result}`;
      this.recordDebugResponse(code, resultStr);
      this.log(`910 响应 HTTP ${code}`);
      if (code < 200 || code >= 300) {
        this.log(`910 失败: HTTP ${code} ${resultStr.substring(0, 120)}`);
        return;
      }
      const okStr = this.extractQuoted(resultStr, 'ok');
      const okBool = resultStr.indexOf('"ok":true') >= 0 || resultStr.indexOf('"ok": true') >= 0 ||
        okStr === 'true';
      if (!okBool) {
        const reason = this.extractQuoted(resultStr, 'reason');
        const msg = this.extractQuoted(resultStr, 'msg');
        if (reason === 'beyond_capability') {
          this.log(`超出元操作库能力，不下发: ${msg.length > 0 ? msg : '无详细说明'}`);
        } else {
          this.log(`910 ok=false${reason.length > 0 ? ` (${reason})` : ''}: ${msg.length > 0 ? msg : resultStr.substring(0, 120)}`);
        }
        return;
      }
      const actions = this.parseActionsFromResponse(resultStr);
      if (actions === null) {
        this.log('无法解析 actions');
        return;
      }
      const err = this.validateMetaActions(actions);
      if (err.length > 0) {
        this.log(`安全拦截，整单拒绝: ${err}`);
        return;
      }
      this.log(`校验通过，共 ${actions.length} 步`);
      this.logMetaActions(actions);

      if (this.isDebugMode) {
        this.pendingActions = actions;
        this.hasPendingDispatch = true;
        this.log(`调试模式：已缓存 ${actions.length} 步，确认后点「下发到狗」`);
        return;
      }
      if (!this.isAuthed) {
        this.log('狗机未连接，规划结果仅展示，不下发执行；连接鉴权后可再发或手动控狗');
        return;
      }
      this.log('开始下发执行');
      await this.executeMetaActions(actions);
    } catch (e) {
      const err = e as BusinessError;
      this.recordDebugResponse(-1, `请求异常 code=${err.code}\nmessage=${err.message}`);
      this.log(`910 请求异常: ${err.code} ${err.message}`);
    } finally {
      try {
        req.destroy();
      } catch (_) {
        // ignore
      }
      this.isPlanning = false;
    }
  }

  /** 调试模式：将缓存的校验通过序列下发到已鉴权狗机 */
  private async dispatchPendingToDog(): Promise<void> {
    if (!this.isDebugMode) {
      this.log('请先进入调试模式');
      return;
    }
    if (this.isProtectMode) {
      this.log('保护模式中，无法下发');
      return;
    }
    if (this.isPlayingSequence || this.isPlanning) {
      this.log('正在规划或执行中，请稍候');
      return;
    }
    if (!this.hasPendingDispatch || this.pendingActions === null || this.pendingActions.length === 0) {
      this.log('没有可下发的规划结果，请先发送到 910');
      return;
    }
    if (!this.isAuthed) {
      this.log('狗机未连接，无法下发；请先发现并连接狗机');
      return;
    }
    const actions = this.pendingActions;
    this.log(`手动下发 ${actions.length} 步到狗机`);
    await this.executeMetaActions(actions);
  }

  /** 将规划结果摘要写入日志（未连狗时便于联调查看） */
  private logMetaActions(actions: MetaAction[]): void {
    for (let i = 0; i < actions.length; i++) {
      const a = actions[i];
      if (a.op === 'mode') {
        this.log(`  [${i + 1}] mode key=${a.key}`);
      } else {
        this.log(
          `  [${i + 1}] vel fwd=${a.fwd.toFixed(2)} side=${a.side.toFixed(2)} ` +
            `yaw=${a.yaw.toFixed(2)} dur=${a.duration_ms}ms`
        );
      }
    }
  }

  /** 申请麦克风权限；已授权则直接 true */
  private async ensureMicPermission(): Promise<boolean> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const atManager = abilityAccessCtrl.createAtManager();
      const tokenId = context.applicationInfo.accessTokenId;
      const status = await atManager.checkAccessToken(tokenId, PERM_MICROPHONE);
      if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return true;
      }
      const result = await atManager.requestPermissionsFromUser(context, [PERM_MICROPHONE]);
      if (result.authResults.length > 0 &&
        result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return true;
      }
      this.log('未授予麦克风权限，无法语音听写');
      return false;
    } catch (e) {
      const err = e as BusinessError;
      this.log(`申请麦克风权限失败: ${err.code} ${err.message}`);
      return false;
    }
  }

  /** 释放语音引擎与听写状态 */
  private stopVoiceRecognition(announce: boolean = true): void {
    const wasListening = this.isVoiceListening;
    this.isVoiceListening = false;
    if (this.asrEngine !== null) {
      try {
        this.asrEngine.finish(VOICE_SESSION_ID);
      } catch (_) {
        // ignore
      }
      try {
        this.asrEngine.cancel(VOICE_SESSION_ID);
      } catch (_) {
        // ignore
      }
      try {
        this.asrEngine.shutdown();
      } catch (_) {
        // ignore
      }
      this.asrEngine = null;
    }
    if (announce && wasListening) {
      this.log(this.nlText.trim().length > 0 ? `听写结束: ${this.nlText}` : '听写已停止');
    }
  }

  /**
   * 语音按钮：开始 / 停止 CoreSpeechKit 麦克风听写。
   * 识别中间结果与最终结果写入 nlText；设备不支持时提示改用输入法语音。
   */
  private async onVoiceButtonClick(): Promise<void> {
    if (this.isProtectMode) {
      this.log('保护模式中，无法语音听写');
      return;
    }
    if (this.isPlanning || this.isPlayingSequence) {
      this.log('规划或执行中，请稍候再听写');
      return;
    }
    if (this.isVoiceListening) {
      this.stopVoiceRecognition(true);
      return;
    }
    if (!canIUse('SystemCapability.AI.SpeechRecognizer')) {
      this.log('本机不支持语音识别引擎，请点指令框用输入法麦克风听写');
      return;
    }
    const ok = await this.ensureMicPermission();
    if (!ok) {
      return;
    }

    try {
      // 先清掉旧引擎，避免 busy
      this.stopVoiceRecognition(false);

      const initParams: speechRecognizer.CreateEngineParams = {
        language: 'zh-CN',
        online: 1
      };
      const engine = await speechRecognizer.createEngine(initParams);
      this.asrEngine = engine;

      const listener: speechRecognizer.RecognitionListener = {
        onStart: (_sessionId: string, _msg: string) => {
          this.isVoiceListening = true;
          this.log('正在听写，请说话；再点「停止」结束');
        },
        onEvent: (_sessionId: string, _code: number, _msg: string) => {
          // 可选：VAD 等事件
        },
        onResult: (_sessionId: string, result: speechRecognizer.SpeechRecognitionResult) => {
          if (result.result !== undefined && result.result.length > 0) {
            this.nlText = result.result;
          }
          if (result.isLast) {
            this.isVoiceListening = false;
            this.log(`听写完成: ${this.nlText}`);
            // 最终结果后释放引擎，下次重新 create
            if (this.asrEngine !== null) {
              try {
                this.asrEngine.shutdown();
              } catch (_) {
                // ignore
              }
              this.asrEngine = null;
            }
          }
        },
        onComplete: (_sessionId: string, _msg: string) => {
          this.isVoiceListening = false;
          if (this.asrEngine !== null) {
            try {
              this.asrEngine.shutdown();
            } catch (_) {
              // ignore
            }
            this.asrEngine = null;
          }
        },
        onError: (_sessionId: string, code: number, msg: string) => {
          this.isVoiceListening = false;
          this.log(`语音识别错误 ${code}: ${msg}`);
          if (this.asrEngine !== null) {
            try {
              this.asrEngine.shutdown();
            } catch (_) {
              // ignore
            }
            this.asrEngine = null;
          }
        }
      };
      engine.setListener(listener);

      const audioInfo: speechRecognizer.AudioInfo = {
        audioType: 'pcm',
        sampleRate: 16000,
        soundChannel: 1,
        sampleBit: 16
      };
      const extraParams: Record<string, Object> = {
        'recognitionMode': 0,
        'vadBegin': 2000,
        'vadEnd': 3000,
        'maxAudioDuration': 20000
      };
      const startParams: speechRecognizer.StartParams = {
        sessionId: VOICE_SESSION_ID,
        audioInfo: audioInfo,
        extraParams: extraParams
      };
      this.isVoiceListening = true;
      this.log('正在听写，请说话…');
      engine.startListening(startParams);
    } catch (e) {
      this.isVoiceListening = false;
      this.asrEngine = null;
      const err = e as BusinessError;
      this.log(`启动语音识别失败: ${err.code} ${err.message}；也可点指令框用输入法麦克风`);
    }
  }

  /** 从 TouchEvent 取相对摇杆中心的偏移 */
  private touchOffsetFromCenter(event: TouchEvent): [number, number] {
    const t = event.touches.length > 0 ? event.touches[0] : event.changedTouches[0];
    const cx = JOYSTICK_SIZE / 2;
    const cy = JOYSTICK_SIZE / 2;
    return [t.x - cx, t.y - cy];
  }

  /**
   * 发送模式切换按键（与狗端键盘接口字母一致）：
   * r 阻尼 / x 空闲(仅手动，云端规划禁止) / z 站立 / v 行走 / b 后空翻 / j 跳跃 / k 挥手
   * 先强制摇杆回中并锁定，再发 mode，与狗端「清零 + 忽略杆量直到回中」对齐。
   */
  async sendModeKey(key: string): Promise<void> {
    if (this.isProtectMode) {
      this.log('保护模式中，无法切模式');
      return;
    }
    if (this.isPlayingSequence) {
      this.log('序列执行中，请稍候或急停');
      return;
    }
    if (!this.isAuthed) {
      this.log('尚未鉴权');
      return;
    }
    try {
      this.engageModeStickGate();
      await this.sendTcpLine(`{"type":"mode","key":"${key}"}`);
      if (!this.stickVelLocked) {
        this.log(`模式: ${key}`);
      } else {
        this.log(`模式: ${key} · 请松手回中后再拨杆`);
      }
    } catch (err) {
      const e = err as BusinessError;
      this.log(`发送模式失败: ${e.code}`);
    }
  }

  /**
   * 切换狗端控制外设（TCP switch）。
   * @param mode RemoteCommandType：1 键盘 / 2 手柄 / 3 手机
   *
   * 流程：先发零速 → 发 switch → 停止本地速度环并断开 TCP（控制权已交出）。
   */
  async sendSwitchRemote(mode: number): Promise<void> {
    if (!this.isAuthed) {
      this.log('尚未鉴权，无法切换控制源');
      return;
    }
    if (mode === REMOTE_OH_PHONE) {
      this.log('当前已是手机控制');
      return;
    }
    if (this.isSwitchingRemote) {
      return;
    }
    this.isSwitchingRemote = true;
    try {
      // 交出控制前先停速，避免切换瞬间残留速度
      this.leftKnobX = 0;
      this.leftKnobY = 0;
      this.rightKnobX = 0;
      this.rightKnobY = 0;
      this.holdFwd = 0;
      this.holdSide = 0;
      this.holdYaw = 0;
      this.leftTouchActive = false;
      this.rightTouchActive = false;
      this.stickVelLocked = false;
      await this.sendTcpLine('{"type":"vel","fwd":0,"side":0,"yaw":0}');
      await this.sendTcpLine(`{"type":"switch","mode":${mode}}`);
      this.stopVelLoop();
      await this.disconnectTcp(true);
      this.log(`已切换到${remoteCommandLabel(mode)}控制，手机已断开`);
    } catch (err) {
      const e = err as BusinessError;
      this.log(`切换控制源失败: ${e.code}`);
    } finally {
      this.isSwitchingRemote = false;
    }
  }

  /**
   * 页面退出时的资源回收：
   * 发现定时器 → 速度环 → TCP → UDP 监听与关闭。
   */
  async cleanupAll(): Promise<void> {
    this.sequenceCancel = true;
    this.isPlayingSequence = false;
    this.isPlanning = false;
    this.stopVoiceRecognition(false);
    if (this.discoverTimerId >= 0) {
      clearTimeout(this.discoverTimerId);
      this.discoverTimerId = -1;
    }
    this.stopVelLoop();
    await this.disconnectTcp();
    if (this.udp !== null) {
      try {
        this.udp.off('message');
        this.udp.off('error');
        await this.udp.close();
      } catch (_) {
        // ignore
      }
      this.udp = null;
    }
  }

  /** 连接状态文案 */
  private statusLabel(): string {
    if (this.isProtectMode) {
      return '保护模式 · 急停锁定';
    }
    if (this.isPlayingSequence) {
      return '元动作序列执行中…';
    }
    if (this.isAuthed) {
      return this.connectedLabel;
    }
    if (this.isConnected) {
      return `鉴权中 · ${this.connectedLabel}`;
    }
    return '未连接 · 同网后发现设备';
  }

  /** 状态指示色：保护红 / 已鉴权青绿 / 连接中琥珀 / 未连接灰 */
  private statusColor(): string {
    if (this.isProtectMode) {
      return '#DC2626';
    }
    if (this.isAuthed) {
      return '#0F766E';
    }
    if (this.isConnected) {
      return '#C2410C';
    }
    return '#64748B';
  }

  /** 分区小标题 */
  @Builder
  SectionLabel(title: string, hint: string) {
    Row() {
      Row({ space: 8 }) {
        Column()
          .width(3)
          .height(14)
          .borderRadius(2)
          .backgroundColor('#0F766E')
        Text(title)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#0F1C24')
          .letterSpacing(1.2)
      }
      Blank()
      Text(hint)
        .fontSize(11)
        .fontColor('#94A3B8')
    }
    .width('100%')
    .padding({ left: 2, right: 4, bottom: 10 })
  }

  /**
   * 虚拟摇杆：外圈 + 可拖动摇杆帽。
   * @param title 左/右说明
   * @param hint 轴映射提示
   * @param isLeft true=平移，false=转向
   */
  @Builder
  JoystickPad(title: string, hint: string, isLeft: boolean) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor('#94A3B8')
        .letterSpacing(0.8)
      Stack() {
        Circle()
          .width(JOYSTICK_SIZE)
          .height(JOYSTICK_SIZE)
          .fill('#15202B')
          .stroke(this.stickVelLocked ? '#F59E0B66' : '#334155')
          .strokeWidth(1.5)
        Circle()
          .width(JOYSTICK_SIZE * 0.62)
          .height(JOYSTICK_SIZE * 0.62)
          .fill('#00000000')
          .stroke('#33415588')
          .strokeWidth(1)
        Column()
          .width(1)
          .height(JOYSTICK_SIZE * 0.38)
          .backgroundColor('#33415599')
        Row()
          .width(JOYSTICK_SIZE * 0.38)
          .height(1)
          .backgroundColor('#33415599')
        Circle()
          .width(JOYSTICK_KNOB)
          .height(JOYSTICK_KNOB)
          .fill(this.stickVelLocked ? '#F59E0B' : (this.isAuthed ? '#2DD4BF' : '#64748B'))
          .shadow({
            radius: 10,
            color: this.stickVelLocked ? '#F59E0B55' : '#14B8A655',
            offsetX: 0,
            offsetY: 3
          })
          .translate({
            x: isLeft ? this.leftKnobX : this.rightKnobX,
            y: isLeft ? this.leftKnobY : this.rightKnobY
          })
      }
      .width(JOYSTICK_SIZE)
      .height(JOYSTICK_SIZE)
      .clip(false)
      .onTouch((event: TouchEvent) => {
        if (!this.isAuthed) {
          return;
        }
        if (event.type === TouchType.Down || event.type === TouchType.Move) {
          if (isLeft) {
            this.leftTouchActive = true;
          } else {
            this.rightTouchActive = true;
          }
          if (this.stickVelLocked) {
            if (isLeft) {
              this.leftKnobX = 0;
              this.leftKnobY = 0;
              this.holdFwd = 0;
              this.holdSide = 0;
            } else {
              this.rightKnobX = 0;
              this.rightKnobY = 0;
              this.holdYaw = 0;
            }
            return;
          }
          const off = this.touchOffsetFromCenter(event);
          if (isLeft) {
            this.applyLeftStick(off[0], off[1]);
          } else {
            this.applyRightStick(off[0], off[1]);
          }
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          if (isLeft) {
            this.leftTouchActive = false;
            this.resetLeftStick();
          } else {
            this.rightTouchActive = false;
            this.resetRightStick();
          }
        }
      })
      Text(this.stickVelLocked ? '松手解锁' : hint)
        .fontSize(10)
        .fontColor(this.stickVelLocked ? '#F59E0B' : '#64748B')
    }
    .alignItems(HorizontalAlign.Center)
  }

  /** 模式切换键 */
  @Builder
  ModeBtn(title: string, keyHint: string, key: string) {
    Column() {
      Text(title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.isAuthed ? '#0F1C24' : '#94A3B8')
      Text(keyHint)
        .fontSize(10)
        .fontColor('#94A3B8')
        .margin({ top: 2 })
    }
    .justifyContent(FlexAlign.Center)
    .width('23%')
    .height(54)
    .margin({ bottom: 8 })
    .backgroundColor(this.isAuthed ? '#FFFFFF' : '#F1F5F9')
    .borderRadius(12)
    .border({ width: 1, color: this.isAuthed ? '#E2E8F0' : '#CBD5E1' })
    .opacity(this.isAuthed ? 1 : 0.7)
    .onClick(() => {
      if (!this.isAuthed) {
        this.log('尚未鉴权');
        return;
      }
      this.sendModeKey(key);
    })
  }

  /**
   * 页面布局：品牌头 → 可滚区 → 底部固定双摇杆。
   */
  build() {
    Column() {
      // —— 品牌头 ——
      Column() {
        Row() {
          Column() {
            Text('RoboPi')
              .fontSize(32)
              .fontWeight(FontWeight.Bold)
              .fontColor('#0F1C24')
              .letterSpacing(0.6)
            Text('局域网控狗 · 端云自然语言')
              .fontSize(13)
              .fontColor('#64748B')
              .margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Column() {
            Text(this.isAuthed ? '已连接' : (this.isConnected ? '鉴权中' : '未连接'))
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
          }
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(20)
          .backgroundColor(this.statusColor())
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 20, right: 20, top: 26, bottom: 14 })
      .linearGradient({
        angle: 160,
        colors: [['#CCFBF1', 0], ['#E8EEF1', 0.5], ['#F8FAFC', 1]]
      })

      Scroll() {
        Column({ space: 16 }) {
          // —— 连接状态 ——
          Row() {
            Column()
              .width(9)
              .height(9)
              .borderRadius(5)
              .backgroundColor(this.statusColor())
              .margin({ right: 10 })
            Text(this.statusLabel())
              .fontSize(13)
              .fontColor('#334155')
              .layoutWeight(1)
              .maxLines(2)
          }
          .width('100%')
          .padding(14)
          .backgroundColor('#FFFFFF')
          .borderRadius(14)
          .border({ width: 1, color: '#E2E8F0' })
          .shadow({ radius: 8, color: '#0F172A08', offsetX: 0, offsetY: 2 })

          // —— 发现 ——
          Column() {
            this.SectionLabel('设备', 'UDP · 9871')
            Row({ space: 10 }) {
              Button(this.isDiscovering ? '扫描中…' : '发现设备')
                .layoutWeight(1)
                .height(46)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
                .backgroundColor(this.isDiscovering ? '#94A3B8' : '#0F766E')
                .borderRadius(12)
                .enabled(!this.isDiscovering)
                .onClick(() => {
                  this.startDiscover();
                })
              Button(this.isConnected ? '断开' : '帮助')
                .width(88)
                .height(46)
                .fontSize(14)
                .fontColor('#0F1C24')
                .backgroundColor('#FFFFFF')
                .borderRadius(12)
                .border({ width: 1, color: '#CBD5E1' })
                .onClick(() => {
                  if (this.isConnected) {
                    this.disconnectTcp();
                  } else {
                    this.log('同网后点「发现设备」，再点连接');
                  }
                })
            }
            .width('100%')
            .margin({ bottom: 12 })

            Text(`已发现 ${this.dogs.length} 台`)
              .fontSize(12)
              .fontColor('#64748B')
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 8 })

            if (this.dogs.length === 0) {
              Text(this.isDiscovering ? '正在监听 announce…' : '暂无设备，请确认狗端 OhPhone 已启动')
                .fontSize(13)
                .fontColor('#94A3B8')
                .width('100%')
                .padding(18)
                .textAlign(TextAlign.Center)
                .backgroundColor('#F8FAFC')
                .borderRadius(12)
                .border({ width: 1, color: '#E2E8F0' })
            } else {
              Column({ space: 8 }) {
                ForEach(this.dogs, (dog: DogDevice) => {
                  Row() {
                    Column() {
                      Text(dog.name)
                        .fontSize(16)
                        .fontWeight(FontWeight.Medium)
                        .fontColor('#0F1C24')
                      Text(`${dog.ip}:${dog.port}`)
                        .fontSize(12)
                        .fontColor('#64748B')
                        .margin({ top: 2 })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    Button(this.isAuthed && this.connectedLabel.indexOf(dog.ip) >= 0 ? '已连' : '连接')
                      .height(36)
                      .padding({ left: 16, right: 16 })
                      .fontSize(13)
                      .fontColor('#FFFFFF')
                      .backgroundColor('#0F766E')
                      .borderRadius(10)
                      .enabled(!this.isDiscovering)
                      .onClick(() => {
                        this.connectDog(dog);
                      })
                  }
                  .width('100%')
                  .padding(14)
                  .backgroundColor('#FFFFFF')
                  .borderRadius(12)
                  .border({ width: 1, color: '#E2E8F0' })
                }, (dog: DogDevice) => dog.key)
              }
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // —— 端云 910：自然语言 → 元动作 ——
          Column() {
            Row() {
              Column() {
                this.SectionLabel('端云规划', '910 · /v1/plan')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Button(this.isDebugMode ? '退出调试' : '调试模式')
                .height(32)
                .fontSize(12)
                .fontColor(this.isDebugMode ? '#FFFFFF' : '#0F766E')
                .backgroundColor(this.isDebugMode ? '#0F766E' : '#FFFFFF')
                .borderRadius(8)
                .border({ width: 1, color: '#0F766E' })
                .padding({ left: 12, right: 12 })
                .onClick(() => {
                  this.toggleDebugMode();
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ bottom: 4 })
            if (this.isDebugMode) {
              Column({ space: 8 }) {
                Text('910 返回（调试）')
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#0F766E')
                  .width('100%')
                Scroll() {
                  Text(this.debugResponseText)
                    .fontSize(12)
                    .fontColor('#334155')
                    .width('100%')
                }
                .width('100%')
                .height(140)
                .scrollBar(BarState.Auto)
                .padding(10)
                .backgroundColor('#F1F5F9')
                .borderRadius(10)
                .border({ width: 1, color: '#CBD5E1' })
                Row({ space: 10 }) {
                  Button('清空返回')
                    .layoutWeight(1)
                    .height(40)
                    .fontSize(13)
                    .fontColor('#0F1C24')
                    .backgroundColor('#FFFFFF')
                    .borderRadius(10)
                    .border({ width: 1, color: '#CBD5E1' })
                    .onClick(() => {
                      this.debugResponseText = '（已清空）等待下一次 910 返回…';
                    })
                  Button(this.hasPendingDispatch ? '下发到狗' : '下发到狗（无缓存）')
                    .layoutWeight(1)
                    .height(40)
                    .fontSize(13)
                    .fontColor('#FFFFFF')
                    .backgroundColor((this.hasPendingDispatch && this.isAuthed && !this.isProtectMode &&
                      !this.isPlayingSequence) ? '#0F766E' : '#94A3B8')
                    .borderRadius(10)
                    .enabled(this.hasPendingDispatch && this.isAuthed && !this.isProtectMode &&
                      !this.isPlayingSequence && !this.isPlanning)
                    .onClick(() => {
                      this.dispatchPendingToDog();
                    })
                }
                .width('100%')
                Text(this.hasPendingDispatch ?
                  (this.isAuthed ? '已校验，可下发到狗' : '已校验，请先连接狗机再下发') :
                  '发送到 910 并校验通过后才会启用「下发到狗」')
                  .fontSize(11)
                  .fontColor('#64748B')
                  .width('100%')
              }
              .width('100%')
              .padding(12)
              .margin({ bottom: 10 })
              .backgroundColor('#ECFDF5')
              .borderRadius(12)
              .border({ width: 1, color: '#99F6E4' })
              .alignItems(HorizontalAlign.Start)
            }
            if (this.isProtectMode) {
              Row({ space: 10 }) {
                Text('保护模式已启用：零速 + 阻尼，控制已锁定')
                  .fontSize(12)
                  .fontColor('#7F1D1D')
                  .layoutWeight(1)
                Button('解除保护')
                  .height(36)
                  .fontSize(13)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#DC2626')
                  .borderRadius(10)
                  .onClick(() => {
                    this.clearProtectMode();
                  })
              }
              .width('100%')
              .padding(12)
              .backgroundColor('#FEE2E2')
              .borderRadius(12)
              .margin({ bottom: 10 })
            }
            TextInput({ placeholder: '中间机地址，如 http://192.168.x.x:8443', text: this.npuBaseUrl })
              .height(42)
              .fontSize(13)
              .backgroundColor('#FFFFFF')
              .borderRadius(10)
              .border({ width: 1, color: '#E2E8F0' })
              .padding({ left: 12, right: 12 })
              .onChange((v: string) => {
                this.npuBaseUrl = v;
              })
            TextInput({ placeholder: 'Bearer token', text: this.npuToken })
              .height(42)
              .fontSize(13)
              .margin({ top: 8 })
              .backgroundColor('#FFFFFF')
              .borderRadius(10)
              .border({ width: 1, color: '#E2E8F0' })
              .padding({ left: 12, right: 12 })
              .onChange((v: string) => {
                this.npuToken = v;
              })
            TextArea({ placeholder: '自然语言指令，例如：向前走两米再坐下', text: this.nlText })
              .height(88)
              .fontSize(14)
              .margin({ top: 8 })
              .backgroundColor('#FFFFFF')
              .borderRadius(10)
              .border({ width: 1, color: '#E2E8F0' })
              .padding(10)
              .onChange((v: string) => {
                this.nlText = v;
              })
            Row({ space: 10 }) {
              Button(this.isVoiceListening ? '停止' : '语音')
                .layoutWeight(1)
                .height(44)
                .fontSize(14)
                .fontColor(this.isVoiceListening ? '#FFFFFF' : '#0F1C24')
                .backgroundColor(this.isVoiceListening ? '#DC2626' : '#FFFFFF')
                .borderRadius(12)
                .border({ width: 1, color: this.isVoiceListening ? '#DC2626' : '#CBD5E1' })
                .enabled(!this.isProtectMode && !this.isPlanning && !this.isPlayingSequence)
                .onClick(() => {
                  this.onVoiceButtonClick();
                })
              Button(this.isPlayingSequence ? '执行中…' : (this.isPlanning ? '规划中…' : '发送到 910'))
                .layoutWeight(2)
                .height(44)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
                .backgroundColor((this.isPlanning || this.isPlayingSequence || this.isProtectMode ||
                  this.isVoiceListening) ? '#94A3B8' : '#0F766E')
                .borderRadius(12)
                .enabled(!this.isPlanning && !this.isPlayingSequence && !this.isProtectMode &&
                  !this.isVoiceListening)
                .onClick(() => {
                  this.submitNaturalCommand();
                })
            }
            .width('100%')
            .margin({ top: 10 })
            Text(this.isDebugMode ?
              '调试中：返回显示在上方框内；校验通过后需点「下发到狗」。退出调试可恢复自动下发。' :
              '点「调试模式」可在页内查看 910 返回并手动下发。普通模式已连狗时会自动执行。')
              .fontSize(11)
              .fontColor('#94A3B8')
              .margin({ top: 8 })
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // —— 模式 ——
          Column() {
            this.SectionLabel('运动模式', '与键盘快捷键一致')
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              this.ModeBtn('阻尼', 'R', 'r')
              this.ModeBtn('空闲', 'X', 'x')
              this.ModeBtn('站立', 'Z', 'z')
              this.ModeBtn('行走', 'V', 'v')
              this.ModeBtn('后空翻', 'B', 'b')
              this.ModeBtn('跳跃', 'J', 'j')
              this.ModeBtn('挥手', 'K', 'k')
            }
            .width('100%')
            .opacity(this.isAuthed ? 1 : 0.55)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // —— 控制源 ——
          Column() {
            this.SectionLabel('控制源', '切换后手机断开')
            Row({ space: 10 }) {
              Column({ space: 4 }) {
                Text('键盘')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.isAuthed ? '#FFFFFF' : '#94A3B8')
                Text('mode = 1')
                  .fontSize(10)
                  .fontColor(this.isAuthed ? '#99F6E4' : '#CBD5E1')
              }
              .justifyContent(FlexAlign.Center)
              .layoutWeight(1)
              .height(56)
              .borderRadius(12)
              .backgroundColor(this.isAuthed ? '#0F766E' : '#E2E8F0')
              .enabled(this.isAuthed && !this.isSwitchingRemote)
              .onClick(() => {
                this.sendSwitchRemote(REMOTE_KEYBOARD);
              })

              Column({ space: 4 }) {
                Text('手柄')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.isAuthed ? '#0F1C24' : '#94A3B8')
                Text('mode = 2')
                  .fontSize(10)
                  .fontColor('#94A3B8')
              }
              .justifyContent(FlexAlign.Center)
              .layoutWeight(1)
              .height(56)
              .borderRadius(12)
              .backgroundColor(this.isAuthed ? '#FFFFFF' : '#F1F5F9')
              .border({ width: 1, color: '#CBD5E1' })
              .enabled(this.isAuthed && !this.isSwitchingRemote)
              .onClick(() => {
                this.sendSwitchRemote(REMOTE_RETROID_GAMEPAD);
              })
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          // —— 日志 ——
          Column() {
            this.SectionLabel('状态', '最近消息')
            Text(this.logText)
              .fontSize(13)
              .fontColor('#334155')
              .lineHeight(20)
              .maxLines(3)
              .width('100%')
              .padding(14)
              .backgroundColor('#F1F5F9')
              .borderRadius(12)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ bottom: 8 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 6 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)

      // —— 底部固定摇杆台 ——
      Column({ space: 6 }) {
        Row() {
          Text('运动')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor('#E2E8F0')
            .letterSpacing(1)
          Blank()
          Text(this.stickVelLocked ? '切模式 · 请松手回中' : '左移 · 右转向')
            .fontSize(11)
            .fontColor(this.stickVelLocked ? '#FBBF24' : '#64748B')
        }
        .width('100%')
        .padding({ left: 4, right: 4 })

        Row() {
          this.JoystickPad('移动', '前后 / 平移', true)
          Column({ space: 8 }) {
            Column() {
              Text('急停')
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
            }
            .justifyContent(FlexAlign.Center)
            .width(68)
            .height(68)
            .borderRadius(34)
            .backgroundColor('#DC2626')
            .shadow({ radius: 12, color: '#DC262666', offsetX: 0, offsetY: 4 })
            .onClick(() => {
              this.emergencyStop();
            })
            Text('E-STOP')
              .fontSize(9)
              .fontColor('#94A3B8')
              .letterSpacing(0.5)
          }
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .layoutWeight(1)
          this.JoystickPad('转向', '左右转', false)
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .padding({ left: 6, right: 6, top: 6, bottom: 8 })
        .linearGradient({
          angle: 180,
          colors: [['#1E293B', 0], ['#0F1C24', 1]]
        })
        .borderRadius(18)
        .opacity(this.isAuthed ? 1 : 0.5)
        .animation({ duration: 200, curve: Curve.EaseInOut })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 6, bottom: 18 })
      .backgroundColor('#F8FAFC')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F8FAFC')
  }
}
