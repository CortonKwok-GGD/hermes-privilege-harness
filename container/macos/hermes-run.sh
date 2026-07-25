#!/bin/bash
# hermes-run: macOS container sandbox via Apple native container CLI
# Deployed to /usr/local/bin/hermes-run on macOS.
# Usage: hermes-run [--no-net] <command>

pgrep -q container-apiserver 2>/dev/null || {
    /usr/local/bin/container system start >/dev/null 2>&1 || {
        echo "Error: failed to start container system" >&2; exit 1
    }
    for i in 1 2 3 4 5; do
        pgrep -q container-apiserver 2>/dev/null && break; sleep 1
    done
}

NO_NET=0; [ "$1" = "--no-net" ] && NO_NET=1 && shift
[ $# -eq 0 ] && echo "Usage: hermes-run [--no-net] <command>" >&2 && exit 1
CNAME="hermes-vm"; [ "$NO_NET" = "1" ] && CNAME="hermes-vm-no-net"

# Volume mounts are configured at container creation (container run), not at exec time.
# See container/macos/rebuild.sh and config.yaml sandbox.mounts for the full list.

# --- Container lifecycle management ---
# 三种状态：运行中 / 已停止 / 不存在
# 不存在时提示用户手动创建，不自动重建
RUNNING=$(/usr/local/bin/container list --quiet 2>/dev/null | grep -x "$CNAME") || true
if [ -z "$RUNNING" ]; then
    if /usr/local/bin/container list --quiet --all 2>/dev/null | grep -x "$CNAME" >/dev/null; then
        # 已停止 → 启动
        /usr/local/bin/container start "$CNAME" 2>&1
    else
        echo "Error: container $CNAME does not exist. Run 'container run' manually." >&2
        exit 1
    fi
fi

# Signal trap — 向容器内转发 ^C
MARKER="/tmp/hrm-$$.pid"

cleanup() {
    echo "" >&2
    echo "  ^C received, terminating..." >&2
    /usr/local/bin/container exec -i "$CNAME" sh -c \
        "kill \$(cat $MARKER 2>/dev/null) 2>/dev/null; rm -f $MARKER" 2>/dev/null || true
    exit 1
}
trap cleanup INT TERM

CMD="$*"
INPUT=$(printf '%s\n' \
    "echo \$\$ > $MARKER" \
    "cd \$HOME/hermes-workspace 2>/dev/null || true" \
    "$CMD; rc=\$?; rm -f $MARKER; exit \$rc")

# 执行命令
echo "$INPUT" | /usr/local/bin/container exec -i "$CNAME" sh 2>&1 && exit 0

# 三阶梯重试（不重启，等容器自行恢复）
for delay in 2 60 600; do
    echo "Warning: exec failed, retrying in ${delay}s..." >&2
    sleep "$delay"
    if echo "$INPUT" | /usr/local/bin/container exec -i "$CNAME" sh 2>&1; then
        exit 0
    fi
done

echo "Error: exec failed after 3 retries, $CNAME may need manual restart" >&2
exit 1
