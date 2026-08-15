#!/usr/bin/env bash
# 打印本机可用于手机填写的局域网 IPv4（排除 127.0.0.1）

set -euo pipefail

echo "[mid] Candidate LAN IPv4 addresses:"
if command -v hostname >/dev/null 2>&1 && hostname -I >/dev/null 2>&1; then
  hostname -I | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' || true
fi

if command -v ip >/dev/null 2>&1; then
  ip -4 -br addr show | awk '$2 ~ /UP|UNKNOWN/ {print}' || true
fi

# 与 910 探测类似的兜底
python3 - <<'PY' 2>/dev/null || python - <<'PY' 2>/dev/null || true
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(("8.8.8.8", 80))
    print("udp_guess_ip:", s.getsockname()[0])
finally:
    s.close()
PY

echo
echo "[mid] Use in App: http://<one-of-above>:8443"
echo "[mid] After tunnel is up: curl -s http://127.0.0.1:8443/health"
