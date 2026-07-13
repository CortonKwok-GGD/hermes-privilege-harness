#!/bin/bash
# Hermes VIP Daemon Watchdog — 自启动 + 自动恢复
# 由 install-macos.sh 在安装时填入实际路径
LOCKFILE="/tmp/hermes-vipd-watchdog.lock"
PIDFILE="/tmp/hermes-vipd.pid"
LOG="/tmp/hermes-vipd-watchdog.log"
VIP_BIN="__VIP_BIN__"
VIP_USER="__VIP_USER__"
VIP_RUN="__VIP_RUN__"

if [ -f "$LOCKFILE" ]; then
    OLD=$(cat "$LOCKFILE" 2>/dev/null)
    if ps -p "$OLD" >/dev/null 2>&1; then exit 0; fi
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$PIDFILE" "$LOCKFILE"' EXIT

start_daemon() {
    echo "$(date) Starting VIP daemon..." >> "$LOG"
    cd /tmp
    HOME=/var/empty sudo -u "$VIP_USER" "$VIP_BIN" 2>>"$LOG" &
    local dpid=$!
    echo "$dpid" > "$PIDFILE"
    # 等 daemon 创建 socket
    for i in $(seq 1 30); do
        [ -S "$VIP_RUN/request.sock" ] && break
        sleep 0.2
    done
}

start_daemon
while true; do
    PID=$(cat "$PIDFILE" 2>/dev/null)
    if [ -z "$PID" ] || ! ps -p "$PID" >/dev/null 2>&1; then
        echo "$(date) Daemon exited, restarting..." >> "$LOG"
        sleep 3
        start_daemon
    fi
    sleep 10
done
