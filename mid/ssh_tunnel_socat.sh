#!/usr/bin/env bash
# 中间机备选：SSH 只绑 127.0.0.1，再用 socat 暴露到局域网
# 当 ssh -L 0.0.0.0 被拒绝（GatewayPorts 等）时使用。
# 依赖：socat（apt/dnf/brew 安装）
#
# 环境变量同 ssh_tunnel.sh：SSH_HOST、LOCAL_PORT、REMOTE_PORT

set -euo pipefail

SSH_HOST="${SSH_HOST:-huawei-dev}"
LOCAL_PORT="${LOCAL_PORT:-8443}"
REMOTE_PORT="${REMOTE_PORT:-8443}"
SSH_LOCAL="${SSH_LOCAL:-18443}"   # SSH 隧道本机侧端口（仅本机）

if ! command -v socat >/dev/null 2>&1; then
  echo "[mid] socat not found. Install it, or use ./ssh_tunnel.sh instead." >&2
  exit 1
fi

cleanup() {
  [[ -n "${SSH_PID:-}" ]] && kill "${SSH_PID}" 2>/dev/null || true
  [[ -n "${SOCAT_PID:-}" ]] && kill "${SOCAT_PID}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "[mid] ssh -L 127.0.0.1:${SSH_LOCAL} -> ${SSH_HOST}:127.0.0.1:${REMOTE_PORT}"
ssh -N -L "127.0.0.1:${SSH_LOCAL}:127.0.0.1:${REMOTE_PORT}" "${SSH_HOST}" &
SSH_PID=$!
sleep 1

echo "[mid] socat 0.0.0.0:${LOCAL_PORT} -> 127.0.0.1:${SSH_LOCAL}"
socat "TCP-LISTEN:${LOCAL_PORT},bind=0.0.0.0,fork,reuseaddr" "TCP:127.0.0.1:${SSH_LOCAL}" &
SOCAT_PID=$!

echo "[mid] Ready. Phone: http://<this-LAN-IP>:${LOCAL_PORT}"
echo "[mid] Self-test: curl -s http://127.0.0.1:${LOCAL_PORT}/health"
wait
