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

# Build volume args from config.yaml
VOLUME_ARGS=""
for CFG in "$HOME/.hermes/plugins/hermes-vip/config.yaml" "$HOME/.hermes/config.yaml"; do
    [ -f "$CFG" ] || continue
    VOLUMES=$(python3 -c "
import yaml, os
c = yaml.safe_load(open('$CFG'))
for m in c.get('sandbox', {}).get('mounts', []):
    host = os.path.expandvars(os.path.expanduser(m['path']))
    ro = ':ro' if not m.get('writable', False) else ''
    print('-v ' + host + ':' + host + ro, end=' ')
" 2>/dev/null)
    [ -n "$VOLUMES" ] && VOLUME_ARGS="$VOLUMES" && break
done
[ -z "$VOLUME_ARGS" ] && VOLUME_ARGS="-v $HOME/hermes-workspace:$HOME/hermes-workspace"

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

CMD="$*"
printf '%s\n' "cd $HOME/hermes-workspace 2>/dev/null || true" "$CMD" \
    | /usr/local/bin/container exec -i "$CNAME" sh 2>&1 || {
    # exec 失败（如容器半死）→ 重启后重试一次
    echo "Warning: exec failed, restarting $CNAME and retrying..." >&2
    /usr/local/bin/container restart "$CNAME" >/dev/null 2>&1
    sleep 2
    printf '%s\n' "cd $HOME/hermes-workspace 2>/dev/null || true" "$CMD" \
        | /usr/local/bin/container exec -i "$CNAME" sh 2>&1 || {
        echo "Error: failed to run in $CNAME" >&2
        exit 1
    }
}
