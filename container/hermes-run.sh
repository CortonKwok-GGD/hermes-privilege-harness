#!/bin/bash
# hermes-run — unified container sandbox entry (deployed to /usr/local/bin/hermes-run)
# 用法: hermes-run [--no-net] <command>
# 底层: hermes-container-ctl exec —— docker / apple 双平台共用同一套代码
NO_NET=0
[ "${1:-}" = "--no-net" ] && NO_NET=1 && shift
[ $# -eq 0 ] && echo "Usage: hermes-run [--no-net] <command>" >&2 && exit 1
CTL="${HERMES_CONTAINER_CTL:-/usr/local/bin/hermes-container-ctl}"
if [ "$NO_NET" = "1" ]; then
    exec "$CTL" exec --no-net "$@"
else
    exec "$CTL" exec "$@"
fi
