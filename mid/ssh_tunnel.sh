#!/usr/bin/env bash
# 中间机：将本机 8443 经 SSH 转发到 910 容器内 127.0.0.1:8443
# 用法：
#   1) 先在 910 上启动 npu_plan_server（--http --port 8443）
#   2) 本机与手机同一局域网，执行本脚本并保持运行
#   3) 手机 App「910 地址」填 http://<本机局域网IP>:8443
#
# 环境变量（可选）：
#   SSH_HOST   SSH config 中的 Host 名，默认 huawei-dev
#   LOCAL_PORT 本机监听端口，默认 8443
#   REMOTE_PORT 910 上服务端口，默认 8443

set -euo pipefail

SSH_HOST="${SSH_HOST:-huawei-dev}"
LOCAL_PORT="${LOCAL_PORT:-8443}"
REMOTE_PORT="${REMOTE_PORT:-8443}"

echo "[mid] SSH tunnel: 0.0.0.0:${LOCAL_PORT} -> ${SSH_HOST}:127.0.0.1:${REMOTE_PORT}"
echo "[mid] Keep this process running. Ctrl+C to stop."
echo "[mid] Phone URL example: http://<this-LAN-IP>:${LOCAL_PORT}"
echo "[mid] Show LAN IP: hostname -I   or   ip -br a"
echo "[mid] Self-test after up: curl -s http://127.0.0.1:${LOCAL_PORT}/health"
echo

# -N: 不执行远程命令，只转发
# -L: 本地监听；0.0.0.0 便于同网手机访问
exec ssh -N -L "0.0.0.0:${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" "${SSH_HOST}"
