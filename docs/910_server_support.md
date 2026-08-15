# 910 端云协同说明

手机自然语言 →（经中间机）→ 910 规划服务 → 元动作序列 → 手机校验后下发机器狗。  
说明从简；**指令尽量给全**。

## 0. 仓库产出一览

| 路径 | 说明 |
|------|------|
| `910_server/` | 910 上 C++ 薄服务源码（stub，固定元动作序列） |
| `mid/` | 中间机：`setup_mid_host.sh` / `ssh_tunnel.sh` / `ssh_tunnel_socat.sh` / `show_lan_ip.sh` |
| `client/ip.ets` | 鸿蒙控狗页：端云 UI、HTTP 调规划、校验、回放、保护模式 |
| `docs/910_server_support.md` | 本说明 |

联调拓扑：

```text
手机 App  --局域网 HTTP-->  中间机(mid/ssh_tunnel.sh)
                                  |  SSH -L
                                  v
                           910 npu_plan_server:8443
```

---

## 1. 使用说明（推荐按此顺序）

### 1.1 910 上启动规划服务

将 `910_server/` 拷到作业机后：

```bash
cd 910_server
make
./npu_plan_server --http --port 8443 --token robotpi
```

本机确认：

```bash
curl -s http://127.0.0.1:8443/health
# → {"ok":true,"service":"npu_plan_server"}

curl -s -X POST http://127.0.0.1:8443/v1/plan \
  -H 'Authorization: Bearer robotpi' -H 'Content-Type: application/json' \
  -d '{"v":1,"request_id":"t1","text":"向前走两米"}'
```

### 1.2 中间机一次性配置（精简）

本机要当中间机时，先保证能 `ssh huawei-dev`：

1. 私钥：将 `KeyPair-8514.pem` 放到 `~/.ssh/KeyPair-8514.pem`，`chmod 600`  
2. `~/.ssh/config` 增加 Host（示例）：

```sshconfig
Host huawei-dev
    HostName dev-modelarts-cnnorth9.huaweicloud.com
    Port 32061
    User ma-user
    IdentityFile ~/.ssh/KeyPair-8514.pem
    IdentitiesOnly yes
    GatewayPorts yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

3. 检查：`./mid/setup_mid_host.sh`（缺密钥会提示路径；成功后再开隧道）

与手机同一 Wi‑Fi；若防火墙拦截则放行本机 **8443/tcp**。

### 1.3 中间机打开隧道

**隧道脚本会占住当前终端**，请再开一个终端跑查 IP / curl。

```bash
# 终端 A（仓库根目录）
chmod +x mid/*.sh
./mid/ssh_tunnel.sh          # 保持运行；Ctrl+C 结束
# 若报错无法绑 0.0.0.0：
# ./mid/ssh_tunnel_socat.sh  # 需 socat

# 终端 B
./mid/show_lan_ip.sh
env -u http_proxy -u https_proxy curl -s http://127.0.0.1:8443/health
```

可选：`SSH_HOST` / `LOCAL_PORT` / `REMOTE_PORT`。等价：`ssh -N -L 0.0.0.0:8443:127.0.0.1:8443 huawei-dev`。

### 1.4 手机 App

1. DevEco 使用 `client/ip.ets` 编译部署（需 `ohos.permission.INTERNET`）。  
2. 「端云规划」里 **910 地址** 填：`http://<中间机局域网IP>:8443`（勿填 ModelArts 出口 NAT IP）。  
3. **Bearer token** 与服务端一致（默认 `robotpi`）。  
4. 先「发现设备」并连接鉴权狗机，再输入自然语言 →「发送到 910」。  
5. 「语音」：CoreSpeechKit 麦克风听写写入指令框（需在 module.json5 声明 `MICROPHONE` 与 `$string:mic_reason`）；也可改用输入法麦克风。  
6. 异常时点 **急停** → 保护模式；确认安全后点 **解除保护**。

### 1.5 为何不能手机直连 910

ModelArts **训练作业**只开 SSH（如 `dev-modelarts-...:32061`），不映射 8443。  
`curl ifconfig.me` 的公网 IP 是出网 NAT，入站不通（已对本机 `出口IP:8443` curl 超时）。  
因此必须经中间机（或日后公网隧道 / 在线服务）。

---

## 2. 通信数据包

`POST {base}/v1/plan`  
Header：`Content-Type: application/json`，`Authorization: Bearer <token>`（默认 `robotpi`）。

请求：

```json
{"v":1,"request_id":"req-001","text":"向前走两米再坐下"}
```

响应成功：

```json
{
  "v": 1,
  "request_id": "req-001",
  "ok": true,
  "actions": [
    {"op": "mode", "key": "v"},
    {"op": "vel", "fwd": 0.4, "side": 0.0, "yaw": 0.0, "duration_ms": 5000},
    {"op": "vel", "fwd": 0.0, "side": 0.0, "yaw": 0.0, "duration_ms": 300},
    {"op": "mode", "key": "r"}
  ],
  "msg": "openclaw"
}
```

超出当前元操作库能力时（**不返回可执行序列**，`actions` 为空）：

```json
{
  "v": 1,
  "request_id": "req-002",
  "ok": false,
  "reason": "beyond_capability",
  "actions": [],
  "msg": "超出当前元操作库能力：仅支持模式切换(mode)与速度段(vel)，无法完成该指令所要求的操作"
}
```

手机收到 `ok=false`（尤其 `reason=beyond_capability`）时只提示，不下发。当前 stub 对含「开门/抓取/飞/爬楼…」等词的指令走此路径；接 openclaw 后由 `kMetaActionSystemPrompt` 判定。

`GET {base}/health` → `{"ok":true,"service":"npu_plan_server"}`

元操作仅两种：

| op | 字段 | 说明 |
|----|------|------|
| `mode` | `key` ∈ `r\|z\|v\|b\|j\|k`（禁止 `x` 空闲，关节释放有安全风险） | 阻尼/站立/行走/后空翻/跳跃/挥手 |
| `vel` | `fwd,side,yaw,duration_ms>0` | 速度段；手机约 100ms 周期下发，到期零速 |

非法步 **整单拒绝**；超速钳位约 0.7/0.5/0.7 并打日志。当前联调全程用 **HTTP**（中间机↔910 由 SSH 加密，不必再在 910 上开 HTTPS）。对接 openclaw 时改 `910_server/main.cpp` 中 `plan_with_openclaw()`。

---

## 3. 910 上采集连接线索

容器内常无 `hostname -I` / `ss` / `ping`，用 curl/python（可先 `conda activate build-tools`）：

```bash
echo "=== 主机名 ==="
hostname 2>/dev/null || echo "${HOSTNAME:-unknown}"

echo "=== 公网出口 IP（出网 NAT；勿作手机直连地址）==="
curl -4 -s --max-time 5 https://api.ip.sb/ip; echo
curl -4 -s --max-time 5 https://ifconfig.me; echo

echo "=== 机内/VPC 私网 IP ==="
python3 - <<'PY' 2>/dev/null || python - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(("8.8.8.8", 80))
    print("udp_guess_ip:", s.getsockname()[0])
finally:
    s.close()
PY

echo "=== 出网 ==="
curl -I --max-time 5 https://www.baidu.com 2>&1 | head -n 5

echo "=== 本机端口是否在听 ==="
python3 - <<'PY' 2>/dev/null || python - <<'PY'
import socket
PORTS = (443, 8443, 8000, 8080, 9443)
for p in PORTS:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.5)
    try:
        r = s.connect_ex(("127.0.0.1", p))
        print(f"127.0.0.1:{p} -> {'open' if r == 0 else 'closed'}")
    finally:
        s.close()
PY

echo "=== 环境变量线索 ==="
env | grep -iE 'HOST|IP|PORT|URL|MODELARTS|ENDPOINT|SERVICE' | sort || true

echo "=== 联调地址模板 ==="
echo "http://<中间机局域网IP>:8443"
```

```bash
curl -s --max-time 3 http://127.0.0.1:8443/health
```

---

## 4. 910 编译、运行、自启

当前方案下 910 只跑 **HTTP**（`--http`）即可：手机到中间机是局域网 HTTP，中间机到 910 走 SSH 隧道，链路已由 SSH 加密，**不必在 910 上再开 HTTPS**。

```bash
cd 910_server
make
./npu_plan_server --http --port 8443 --token robotpi

# 环境变量可选：NPU_PORT、NPU_TOKEN
```

```bash
# systemd（先改 scripts/npu_plan_server.service 里的路径；单元默认已是 --http）
# ModelArts 作业容器上常无 sudo/systemd，不通则用下面的 nohup
sudo cp scripts/npu_plan_server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now npu_plan_server

# 无 systemd / 无 sudo 时（训练作业更常见）
nohup ./npu_plan_server --http --port 8443 --token robotpi >/tmp/npu_plan.log 2>&1 &
```

依赖：910 需 g++/pthread；中间机需 OpenSSH（socat 备选）；Python 调试可用 conda **robotpi**（`pip install requests`）。

（可选）若将来手机直连公网且不用 SSH 隧道，可用 `make certs && make tls` 启 HTTPS；与当前中间机联调无关。

---

## 5. 保护模式

急停后（**阻尼，非关节锁死**）：

1. 中止元动作序列回放  
2. 双摇杆回中，立即下发零速 `vel`  
3. 已鉴权时发送 `mode key=r`  
4. 锁定摇杆 / 模式键 / 自然语言，直至用户点「解除保护」

---

## 6. 手机端修改说明（`client/ip.ets`）

相对原「仅局域网控狗」页面，主要增加：

| 项 | 说明 |
|----|------|
| 端云 UI | 「端云规划」：910 地址、token、自然语言、「语音」、「发送到 910」、调试模式（页内返回区 + 手动下发）、保护条 |
| HTTP 客户端 | `@kit.NetworkKit` 的 `http`：`POST {base}/v1/plan` |
| 元动作 | `MetaAction`；解析 `actions`；整单校验；按序执行 `mode` / 带 `duration_ms` 的 `vel` |
| 保护模式 | `emergencyStop` 升级为停序列 + 零速 + 阻尼 + 锁定 |
| 门控 | 保护中或序列回放中忽略摇杆；序列执行时锁定模式键 |
| 默认常量 | `NPU_BASE_URL=http://127.0.0.1:8443`，`NPU_BEARER_TOKEN=robotpi`（界面可改，未持久化） |

联调时地址务必改为 `http://<中间机LAN>:8443`。字幕提示已写明经 `mid/ssh_tunnel` 再填地址。

---

## 7. 中间机脚本一览（`mid/`）

| 文件 | 作用 |
|------|------|
| `setup_mid_host.sh` | 检查 `~/.ssh` 密钥与 `ssh huawei-dev` |
| `ssh_tunnel.sh` | `ssh -L 0.0.0.0:8443→910:8443`（推荐） |
| `ssh_tunnel_socat.sh` | SSH 只绑本机 + socat 暴露局域网 |
| `show_lan_ip.sh` | 打印候选局域网 IPv4 |
| `README.md` | 短用法 |

详见仓库内 `mid/README.md`。
