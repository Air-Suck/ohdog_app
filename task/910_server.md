目标：实现手机侧前端软件与云端昇腾910之间的端云协同，即手机接收自然指令，然后将指令发送给云端昇腾910进行推理。云端昇腾910将自然语言指令分解为元动作序列，然后将发送结果返回到手机前端软件。手机前端软件进行简单的安全拦截以及必要的数据格式转换之后，将指令下发给机器狗执行。

方案：
1、手机侧前端软件与云端昇腾910之间的应用层通信使用 HTTPS（联调阶段可用 HTTP）；报文为 JSON（见「元操作定义」与 docs/910_server_support.md）
2、云端昇腾910（ModelArts 训练作业容器）上运行薄规划服务 npu_plan_server，监听业务端口（默认 8443）
3、昇腾910上将会运行openclaw+ibrobot，以实现任务分解的功能。但是现在openclaw还没有部署到910b上
4、网络可达性（重要，已实测）：
   - 910 位于华为云 ModelArts「训练作业」中：平台仅为作业开通 SSH 登录入口（如 dev-modelarts-...:32061 → 容器内 sshd），不会自动把容器内 8443 映射到公网
   - 容器「公网出口 IP」（如 curl ifconfig.me 看到的地址）只是出网 NAT，不能当作手机直连地址；本机对该 IP:8443 的 curl 已超时，证明入站不通
   - 因此「手机 App 直接填出口 IP / 私网 IP 访问 910」的原设想不可行（不是协议选错，是没有业务端口入站路径）
5、当前联调方案（局域网中间机 + SSH 端口转发）：
   - 使用已能 SSH 登录 910 的电脑作为中间机；手机与中间机同一局域网
   - 中间机用 ssh -L 将本机端口转发到 910 容器内 127.0.0.1:8443（一段 shell 即可，无需另写业务程序）
   - 手机 App「910 地址」填 http://<中间机局域网IP>:8443，请求经中间机 SSH 隧道到达 910，响应原路返回
   - 适用实验室/同网演示；中间机需保持开机且隧道不断。手机走 4G 或需公网随时访问时，再改用出站隧道（frp/Cloudflare 等）或 ModelArts 在线/推理服务（需控制台权限，非仅 SSH 可完成）

设备
1、910服务器相关信息：
    [ma-user@ma-job-666fdbcc-3af5-436c-9790-87fab5dcb900-worker-0 snh]$ cat /etc/os-release 2>/dev/null; echo '---'; uname -a; echo '---'; [ -f /.dockerenv ] && echo 'dockerenv: yes' || echo 'dockerenv: no'; [ -f /run/.containerenv ] && echo 'containerenv: yes' || echo 'containerenv: no'
    NAME="openEuler"
    VERSION="24.03 (LTS)"
    ID="openEuler"
    VERSION_ID="24.03"
    PRETTY_NAME="openEuler 24.03 (LTS)"
    ANSI_COLOR="0;31"
    ---
    Linux ma-job-666fdbcc-3af5-436c-9790-87fab5dcb900-worker-0 4.19.90-vhulk2211.3.0.h1543.eulerosv2r10.aarch64 #1 SMP Tue Jun 6 07:58:07 UTC 2023 aarch64 aarch64 aarch64 GNU/Linux
    ---
    dockerenv: yes
    containerenv: no
    
    ssh连接方式
    Host huawei-dev
        HostName dev-modelarts-cnnorth9.huaweicloud.com
        Port 32061
        User ma-user
        IdentityFile C:\\Users\\Lenovo\\.ssh\\KeyPair-8514.pem
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
    在服务器上有常见的编译工具
2、手机端相关信息：
    HarmonyOS6.1，代码使用deveco编译部署

元操作定义（两端必须遵守；通信外层 JSON 可自行扩展字段，但 actions 内步骤不得超出本字典）：
1、设计目标：拆解结果应对齐手柄控制能力——既含模式切换，也含速度控制，而不是仅返回模式键列表。
2、元操作库仅允许以下两种步骤（与现有 client/ip.ets 下发能力一致）：
    A. mode — 模式切换，对应现有 TCP mode
       {"op":"mode","key":"<k>"}
       合法 key 仅限：r（阻尼）、x（空闲）、z（站立）、v（行走）、b（后空翻）、j（跳跃）、k（挥手）
    B. vel — 速度段，对应现有 TCP vel（摇杆），必须带持续时间
       {"op":"vel","fwd":<f>,"side":<f>,"yaw":<f>,"duration_ms":<n>}
       坐标系与现有控狗一致：fwd>0 前进、<0 后退；side>0 左移、<0 右移；yaw>0 左转、<0 右转
       duration_ms 必须为 >0 的整数；手机按现有速度环周期（约 100ms）重复下发该速度，到期后发一帧全零 vel
       速度缺省视为 0；数值超出手机端上限（与 ip.ets 中 MAX_FWD/MAX_SIDE/MAX_YAW 一致，当前约 0.7/0.5/0.7）时：钳位到上限并打日志，不因此拒绝整单
3、距离类自然语言（如「向前走两米」）：当前狗端协议无里程闭环，910 侧应用「名义速度 × 时长」近似写入 vel.duration_ms，勿发明新的 distance 字段。
4、安全校验与执行策略（手机端）：
    - 若响应 ok=false（含 reason=beyond_capability）：提示 msg，不下发任何步骤
    - 收到 actions 后逐条校验 op / key / 字段类型 / duration_ms；任一非法 → 整单拒绝，不下发任何步骤（不做「过滤后继续执行」）
    - 合法则严格按数组顺序执行；建议非零 vel 前先确保已处于可行走模式（如 key=v），具体是否由 910 在序列里显式给出 mode，由分解侧保证
    - 急停进入保护模式：立即停止序列回放、双杆回中、下发零速，并切阻尼 mode key=r；拒绝后续 NL/摇杆，直到用户明确解除保护（保护模式细节实现时可再细化，但不得弱于上述行为）
5、响应中 actions 示例（「向前走约两米再坐下/回空闲」，按约 0.4m/s × 5s 近似）：
    {
      "request_id": "req-001",
      "ok": true,
      "actions": [
        {"op": "mode", "key": "v"},
        {"op": "vel", "fwd": 0.4, "side": 0.0, "yaw": 0.0, "duration_ms": 5000},
        {"op": "vel", "fwd": 0.0, "side": 0.0, "yaw": 0.0, "duration_ms": 300},
        {"op": "mode", "key": "x"}
      ]
    }
   超出能力示例（不要返回可执行序列）：
    {
      "request_id": "req-002",
      "ok": false,
      "reason": "beyond_capability",
      "actions": [],
      "msg": "超出当前元操作库能力：……"
    }
   连通性测试桩可固定返回上述或同结构的短序列；明显超能力指令应返回 beyond_capability。
   910 侧 system prompt（kMetaActionSystemPrompt）须包含元操作字典，并要求模型在无法用字典完成时输出 beyond_capability 对象而非胡编 actions。

要求：
1、通信相关代码：手机端代码直接修改client/ip.ets文件，910 server上运行的程序编写在910_server目录下，中间机脚本保存在mid目录下
2、手机端代码逻辑：在现有基础上，增加语音功能以及对话框，以捕捉自然语言指令。用户在应用上输入指令之后，将自然语言指令发送到910 server上进行推理。推理结果再返回给手机端软件。接收到返回值之后，手机端需按上文「元操作定义」校验整单；全部合法后再按序下发到机器狗（mode → sendModeKey；vel → 按时长喂速度环）。另外需要有安全保护机制，即如果我发现实机执行的时候出现问题，我在控制设备上按急停键需要马上进入保护模式（行为见上文，可再细化）。需要有相关信息的输出，且在代码中需要有详细的注释
3、服务器端代码逻辑：在服务端代码为一个自启动薄服务器进程，将会等待手机端的连接。连接之后需要将从手机端接收到的语言指令转发给ib robot和openclaw实现任务到元操作的分解。分解结束之后，将元操作序列返回到手机端（actions 必须符合上文元操作字典）。服务器端代码使用cpp编写。需要有相关信息的输出，且在代码中需要有详细的注释。由于现在910上还没有部署openclaw和ibrobot，所以建议现在先写一个简单的测试进程以测试连通性，即接收自然语言指令之后，返回一个固定的元操作序列。待openclaw和ibrobot部署完成之后，再进行修改。
4、中间机搭建：使用已能 SSH 登录 910 的电脑作为中间机；手机与中间机同一局域网。中间机用 ssh -L 将本机端口转发到 910 容器内 127.0.0.1:8443（一段 shell 即可，无需另写业务程序）
5、消息格式：HTTPS JSON 请求/响应外层字段可自行定义，但返回的元操作序列必须严格遵循上文「元操作定义」（仅 mode / vel 两种 op，字段与校验策略如上）。完整数据包定义写入 docs/910_server_support.md
6、可执行文件：不需要可执行文件。由于服务器端可以进行代码编译，所以服务器端代码提供源码即可；手机端代码我将会拷贝到deveco中进行编译运行
7、需要保存相关的文档到docs目录下。文档需要包含：
    1、手机侧前端软件和云端昇腾910之间的通信数据包定义（含元操作字典与示例）
    2、连接服务器时所需要的信息如何在服务器上查询（提供相关指令以及简短注释即可）
    3、如何在云端昇腾910上实现部署（代码如何编译，如何运行等）
    4、执行过程中如果需要额外安装什么包的话，请使用当前设备上的robotpi环境
    5、机器狗保护模式的行为（急停后：停序列、零速、阻尼 mode=r、锁定控制直至解除等）
    6、你对手机端程序的修改内容及相关说明
    7、命名为910_server_support.md，文档内容尽量精简