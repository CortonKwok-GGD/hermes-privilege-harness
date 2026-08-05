#!/bin/bash
# hermes-run — unified container sandbox entry (deployed to /usr/local/bin/hermes-run)
# 用法: hermes-run [--no-net] <command>
# 底层: hermes-container-ctl exec —— docker / apple 双平台共用同一套代码
#
# 执行审计: 每次容器执行记录到 /var/log/hermes-vip/run.log
#   [时间] RUN  cmd=<截断命令>  rc=<退出码>  dur_ms=<耗时>
# FIFO: 超 RUN_LOG_MAX_BYTES 滚动保留 .1, 最旧一代覆盖丢弃（与 audit.log 同模式）。
# 权限: install.sh 创建 run.log 为组写(664, hermes-vip 组)；写失败静默降级，不阻断执行。

RUN_LOG="/var/log/hermes-vip/run.log"
RUN_LOG_MAX_BYTES=10485760   # 10MB

NO_NET=0
[ "${1:-}" = "--no-net" ] && NO_NET=1 && shift
[ $# -eq 0 ] && echo "Usage: hermes-run [--no-net] <command>" >&2 && exit 1
CTL="${HERMES_CONTAINER_CTL:-/usr/local/bin/hermes-container-ctl}"

# ── FIFO 滚动 + 追加（无 sudo，纯组权限）──
_append_run_log() {
    local line="$1" size
    if [ -f "$RUN_LOG" ]; then
        size=$(wc -c < "$RUN_LOG" 2>/dev/null || echo 0)
        if [ "${size:-0}" -gt "$RUN_LOG_MAX_BYTES" ] 2>/dev/null; then
            [ -f "$RUN_LOG.1" ] && rm -f "$RUN_LOG.1"
            mv "$RUN_LOG" "$RUN_LOG.1" 2>/dev/null || true
        fi
    fi
    printf '%s\n' "$line" >> "$RUN_LOG" 2>/dev/null || true
}

# ── 执行 + 记录退出码/耗时 ──
_start=$(date +%s%N 2>/dev/null || date +%s)
if [ "$NO_NET" = "1" ]; then
    "$CTL" exec --no-net "$@"
else
    "$CTL" exec "$@"
fi
_rc=$?
_end=$(date +%s%N 2>/dev/null || date +%s)
_dur_ms=$(( (_end - _start) / 1000000 ))
[ "$_dur_ms" -lt 0 ] && _dur_ms=0

_cmd="$*"
_append_run_log "[$(date '+%Y-%m-%d %H:%M:%S')]  RUN  cmd=${_cmd:0:200}  rc=$_rc  dur_ms=$_dur_ms"
exit "$_rc"
