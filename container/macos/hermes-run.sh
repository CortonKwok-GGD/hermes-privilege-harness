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

CID=$(/usr/local/bin/container list --quiet --all 2>/dev/null | grep -x "$CNAME")
if [ -z "$CID" ]; then
    NET=""; [ "$NO_NET" = "1" ] && NET="--network none"
    /usr/local/bin/container run -d --name "$CNAME" --arch amd64 $NET $VOLUME_ARGS \
        hermes-vm:latest sleep infinity 2>&1 || {
        echo "Error: failed to create container $CNAME" >&2; exit 1
    }
fi

CMD="$*"
printf '%s\n' "cd $HOME/hermes-workspace 2>/dev/null || true" "$CMD" \
    | /usr/local/bin/container exec -i "$CNAME" sh
