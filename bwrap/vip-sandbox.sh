#!/bin/bash
# Hermes VIP - bwrap 沙箱启动器
# 将 hermes 命令运行在沙箱内

set -euo pipefail

HERMES_BIN="${1:-}"
if [ -z "$HERMES_BIN" ]; then
  HERMES_BIN="$(which hermes 2>/dev/null || echo $HOME/.hermes/bin/hermes)"
fi
shift 2>/dev/null || true

if ! command -v bwrap &>/dev/null; then
  exec "$HERMES_BIN" "$@"
fi

# 沙箱：
#   / → 只读
#   /root → 空
#   ~/.hermes → 可写（保存配置）
#   /run/hermes-vip → 可写（VIP socket）
#   /tmp → 可写
#   无网络

exec bwrap \
  --ro-bind / / \
  --tmpfs /root \
  --tmpfs /opt \
  --bind "$HOME/.hermes" "$HOME/.hermes" \
  --bind /run/hermes-vip /run/hermes-vip \
  --bind /tmp /tmp \
  --unshare-net \
  --unshare-ipc \
  --unshare-pid \
  --dev /dev \
  --proc /proc \
  "$HERMES_BIN" "$@"
