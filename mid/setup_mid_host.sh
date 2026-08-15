#!/usr/bin/env bash
# 在本机（中间机）完成 SSH / 隧道前检查
# 用法：在仓库根目录执行  ./mid/setup_mid_host.sh

set -euo pipefail

KEY="${KEY:-$HOME/.ssh/KeyPair-8514.pem}"
SSH_HOST="${SSH_HOST:-huawei-dev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "[setup] repo=$ROOT"
echo "[setup] expect key at $KEY"

chmod 700 "$HOME/.ssh" 2>/dev/null || true
if [[ -f "$HOME/.ssh/config" ]]; then
  chmod 600 "$HOME/.ssh/config"
  echo "[setup] OK ~/.ssh/config"
else
  echo "[setup] ERROR: missing ~/.ssh/config" >&2
  exit 1
fi

if [[ ! -f "$KEY" ]]; then
  echo "[setup] ERROR: 私钥不存在: $KEY" >&2
  echo "[setup] 请从 Lenovo 拷贝 KeyPair-8514.pem：" >&2
  echo "         Windows: C:\\Users\\Lenovo\\.ssh\\KeyPair-8514.pem" >&2
  echo "         放到本机: $KEY && chmod 600 $KEY" >&2
  echo "         例如 scp / U盘 / 微信文件传输后：" >&2
  echo "           cp /path/to/KeyPair-8514.pem $KEY && chmod 600 $KEY" >&2
  exit 1
fi

chmod 600 "$KEY"
echo "[setup] OK key permissions"

chmod +x "$ROOT"/mid/*.sh
echo "[setup] OK mid/*.sh executable"

echo "[setup] testing: ssh $SSH_HOST 'echo mid-ssh-ok && hostname'"
if ssh -o BatchMode=yes -o ConnectTimeout=15 "$SSH_HOST" 'echo mid-ssh-ok; echo HOST=${HOSTNAME:-unknown}'; then
  echo "[setup] SSH 登录成功"
else
  echo "[setup] ERROR: SSH 失败。检查密钥是否匹配、作业是否仍在运行、端口 32061 是否可达。" >&2
  exit 1
fi

echo
echo "[setup] 下一步："
echo "  1) 确认 910 上已运行: ./npu_plan_server --http --port 8443 --token robotpi"
echo "  2) 终端 A:  $ROOT/mid/ssh_tunnel.sh"
echo "  3) 终端 B:  $ROOT/mid/show_lan_ip.sh"
echo "             env -u http_proxy -u https_proxy curl -s http://127.0.0.1:8443/health"
echo "  4) 手机与本机同一 Wi-Fi，App 填 http://<上面打印的LAN-IP>:8443"
