# 中间机（mid）

能 SSH 登录 910 的电脑：与手机同一局域网，用 SSH 端口转发把手机 HTTP 接到 910。

## 本机首次配置

1. 将 `KeyPair-8514.pem` 拷到 `~/.ssh/KeyPair-8514.pem`（`chmod 600`）  
2. 已写入 `~/.ssh/config` 中的 `Host huawei-dev`（仓库外，在用户家目录）  
3. 检查：

```bash
./mid/setup_mid_host.sh
```

## 开隧道

```bash
chmod +x mid/*.sh

# 1) 910 上已启动 npu_plan_server（8443）
# 2) 终端 A
./mid/ssh_tunnel.sh
# 若 0.0.0.0 绑定失败：
# ./mid/ssh_tunnel_socat.sh

# 3) 终端 B：查本机局域网 IP，填到手机「910 地址」
./mid/show_lan_ip.sh
# App: http://<LAN-IP>:8443

# 4) 自测（若设了代理可去掉）
env -u http_proxy -u https_proxy curl -s http://127.0.0.1:8443/health
```

可选环境变量：`SSH_HOST`（默认 `huawei-dev`）、`LOCAL_PORT`、`REMOTE_PORT`。

详见 `docs/910_server_support.md`。
