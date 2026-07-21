#!/bin/bash
# hermes-serve-proxy — Mac 端代理
# Desktop spawn hermes serve → 拦截 → SSH 隧道 → 沙箱容器 serve
#
# 用法: 放在 PATH 中，Desktop 自动调用
# 部署: cp hermes-serve-proxy ~/.hermes/bin/hermes (替换原 hermes)

set -e

SANDBOX_HOST="${HERMES_SANDBOX_HOST:-10.0.0.3}"
SANDBOX_USER="${HERMES_SANDBOX_USER:-admin}"
SANDBOX_PORT="${HERMES_SANDBOX_PORT:-9119}"

# 找空闲端口
LOCAL_PORT=${HERMES_PROXY_PORT:-$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")}

# 建立 SSH 隧道（后台）
ssh -f -N -L "${LOCAL_PORT}:127.0.0.1:${SANDBOX_PORT}" \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    "${SANDBOX_USER}@${SANDBOX_HOST}" 2>/dev/null

# Desktop 期望的输出格式
echo "HERMES_BACKEND_READY port=${LOCAL_PORT}"

# 保持运行（Desktop 会 kill 这个进程）
trap "ssh -O exit ${SANDBOX_USER}@${SANDBOX_HOST} 2>/dev/null; exit 0" INT TERM
while true; do sleep 10; done
