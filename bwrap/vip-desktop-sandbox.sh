#!/bin/bash
# Hermes VIP - Desktop 版 bwrap 沙箱
# 允许 X11/Wayland/D-Bus/GPU 访问，但禁止写系统路径

set -euo pipefail

HERMES_BIN="${1:-}"
if [ -z "$HERMES_BIN" ]; then
  HERMES_BIN="$(which hermes 2>/dev/null || echo $HOME/.hermes/bin/hermes)"
fi
shift 2>/dev/null || true

if ! command -v bwrap &>/dev/null; then
  exec "$HERMES_BIN" "$@"
fi

# Desktop 沙箱：
#   系统路径只读
#   X11/Wayland/D-Bus/GPU/音频 可访问
#   无网络、无 sudo

exec bwrap \
  --ro-bind / / \
  --tmpfs /root \
  --tmpfs /opt \
  --bind "$HOME/.hermes" "$HOME/.hermes" \
  --bind /run/hermes-vip /run/hermes-vip \
  --bind /tmp /tmp \
  --bind /tmp/.X11-unix /tmp/.X11-unix \
  --bind /run/user /run/user \
  --dev /dev/dri \
  --dev /dev/shm \
  --dev /dev/fd \
  --unshare-net \
  --unshare-ipc \
  --unshare-pid \
  --dev /dev \
  --proc /proc \
  "$HERMES_BIN" "$@"
