#!/bin/bash
# ==============================================================================
# Hermes VIP — macOS 安装（跨版本适配）
# ==============================================================================
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "┌─────────────────────────────────────────────┐"
echo "│  Hermes VIP — macOS 安装                     │"
echo "└─────────────────────────────────────────────┘"
echo ""

[ "$EUID" -eq 0 ] || { echo -e "${RED}❌ 需要 sudo 运行${NC}"; exit 1; }

# ── Hermes 版本检测 ──
MIN_HERMES="0.18.0"
hermes_version() {
    local h="$1"
    "$h" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0"
}
version_gte() {
    # 返回 0 如果 $1 >= $2
    printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 | grep -qx "$1"
}


check_hermes_version() {
    local hbin hver
    # 检测顺序: 用户可能的 hermes 路径
    for hbin in \
        "$REAL_HOME/Library/Application Support/cn.org.hermesagent.desktop/runtime/desktop-bin/hermes" \
        "$REAL_HOME/Library/Application Support/cn.org.hermesagent.desktop/runtime/hermes-home/bin/hermes" \
        "$(sudo -u "$REAL_USER" which hermes 2>/dev/null || echo '')" \
        /opt/homebrew/bin/hermes \
        /usr/local/bin/hermes; do
        hver="$(hermes_version "$hbin")"
        [ "$hver" != "0.0.0" ] && break
    done
    echo "🔍 检测到 Hermes: $hbin v$hver"
    if ! version_gte "$hver" "$MIN_HERMES"; then
        echo -e "${RED}❌ Hermes 版本过低 ($hver < $MIN_HERMES)${NC}"
        echo "   VIP 需要 Hermes >= $MIN_HERMES 才支持原生审批卡片"
        echo "   请升级: hermes update 或下载最新桌面版"
        exit 1
    fi
    HERMES_BIN="$hbin"
    HERMES_VER="$hver"
}

# ── 检测真实用户 ──
REAL_USER=""
# 1. SUDO_USER (sudo ./install.sh 设置)
REAL_USER="${SUDO_USER:-}"
# 2. logname (返回登录用户，最可靠)
[ -z "$REAL_USER" ] && REAL_USER="$(logname 2>/dev/null || echo '')"
# 3. 当前控制台所有者 (macOS 特有，用于无 TTY 环境)
[ -z "$REAL_USER" ] && REAL_USER="$(stat -f '%Su' /dev/console 2>/dev/null || echo '')"
# 4. who am i (需要 TTY，最后兜底)
[ -z "$REAL_USER" ] && REAL_USER="$(who am i 2>/dev/null | awk '{print $1}' || echo '')"
# 5. $HOME 的属主
[ -z "$REAL_USER" ] && REAL_USER="$(ls -ld /Users/* 2>/dev/null | grep -v Shared | head -1 | awk '{print $3}')"

if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    echo -e "${RED}❌ 无法检测当前用户 (got: '$REAL_USER')${NC}"
    echo "   手动指定: REAL_USER=你的用户名 sudo -E bash install.sh"
    exit 1
fi

REAL_HOME="$(eval echo ~$REAL_USER)"
HERMES_HOME="${HERMES_HOME:-$REAL_HOME/.hermes}"

# ── macOS 版本 ──
OS_VER="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VER%%.*}"
[ "$OS_MAJOR" -ge 26 ] && MACOS_26=1 || MACOS_26=0
echo "👤 $REAL_USER ($REAL_HOME)"
echo "🖥  macOS $OS_VER ($([ "$MACOS_26" = 1 ] && echo "26+ LaunchAgent" || echo "<26 LaunchDaemon"))"

# ── 检查 Hermes 版本（必须 >= v0.18 才支持原生审批卡片）──
check_hermes_version
echo "🆗 Hermes $HERMES_VER ($HERMES_BIN)"

# ── Hermes 插件目录检测（CN桌面版 vs 原生桌面版 vs CLI）──
if echo "$HERMES_BIN" | grep -q "cn.org.hermesagent"; then
    HERMES_HOME="$(dirname "$HERMES_BIN")/../hermes-home"
    HERMES_HOME="$(cd "$HERMES_HOME" 2>/dev/null && pwd || echo "$HERMES_HOME")"
    echo "📦 CN Desktop Hermes 检测到"
elif [ -d "$REAL_HOME/Library/Application Support/cn.org.hermesagent.desktop" ]; then
    HERMES_HOME="$REAL_HOME/Library/Application Support/cn.org.hermesagent.desktop/runtime/hermes-home"
    echo "📦 CN Desktop Hermes (目录检测)"
else
    HERMES_HOME="${HERMES_HOME:-$REAL_HOME/.hermes}"
    echo "📦 原生 Hermes / CLI"
fi

# ── 配置 ──
VIP_USER="_hermesvip"
VIP_BIN="/usr/local/bin/hermes-vipd"
VIP_LIB="/usr/local/lib/hermes-vip"
VIP_ETC="/etc/hermes-vip"
VIP_RUN="/var/run/hermes-vip"
VIP_LOG="/var/log/hermes-vip"
LABEL="com.hermes.vipd"

# ── 0. 停旧 ──
echo "🛑 停止旧 daemon..."
if [ "$MACOS_26" = 1 ]; then
    sudo -u "$REAL_USER" launchctl bootout "gui/$(id -u "$REAL_USER")/$LABEL" 2>/dev/null || true
else
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    launchctl unload "/Library/LaunchDaemons/$LABEL.plist" 2>/dev/null || true
fi
sleep 1
echo "  ✅ 已停止"

# ── 1. _hermesvip 用户 ──
if ! id "$VIP_USER" &>/dev/null; then
    U=498; while dscl . -list /Users UniqueID | awk '{print $2}' | grep -qx "$U"; do U=$((U-1)); done
    dscl . -create "/Users/$VIP_USER" UniqueID "$U"
    dscl . -create "/Users/$VIP_USER" UserShell "/usr/bin/false"
    dscl . -create "/Users/$VIP_USER" RealName "Hermes VIP Daemon"
    dscl . -create "/Users/$VIP_USER" NFSHomeDirectory "/var/empty"
    dscl . -create "/Users/$VIP_USER" PrimaryGroupID 1
    echo "  ✅ _hermesvip 创建"
else
    echo "  ⏭  _hermesvip 已存在"
fi

# ── 2. sudoers ──
S="/etc/sudoers.d/$VIP_USER"
if [ ! -f "$S" ]; then
    echo "$VIP_USER ALL=(ALL) NOPASSWD: ALL" > "$S"
    chmod 440 "$S"; chown root:wheel "$S"
    echo "  ✅ _hermesvip sudoers"
fi
# watchdog 需要用 sudo -u _hermesvip 启动 daemon
D="/etc/sudoers.d/hermes-vipd-launch"
if [ ! -f "$D" ]; then
    echo "ALL ALL=($VIP_USER) NOPASSWD: $VIP_BIN" > "$D"
    chmod 440 "$D"; chown root:wheel "$D"
    echo "  ✅ launch sudoers"
fi

# ── 3. daemon ──
mkdir -p "$VIP_LIB/daemon" "$VIP_LIB/connectors"
rm -f "$VIP_LIB"/daemon/*.py "$VIP_LIB"/connectors/*.py 2>/dev/null || true
cp "$PROJECT_DIR/daemon/"*.py "$VIP_LIB/daemon/"
cp "$PROJECT_DIR/connectors/"*.py "$VIP_LIB/connectors/"
touch "$VIP_LIB/__init__.py"
chmod -R 755 "$VIP_LIB"
chown -R root:wheel "$VIP_LIB"

cat > "$VIP_BIN" << 'LB'
#!/bin/bash
export PYTHONPATH="/usr/local/lib/hermes-vip:$PYTHONPATH"
exec /usr/bin/python3 -m daemon.vipd "$@"
LB
chmod 755 "$VIP_BIN"; chown root:wheel "$VIP_BIN"
echo "  ✅ daemon 已安装"

# ── 4. 目录 ──
mkdir -p "$VIP_ETC" "$VIP_RUN" "$VIP_LOG"
chmod 755 "$VIP_ETC" "$VIP_RUN" "$VIP_LOG"
chown root:wheel "$VIP_ETC" "$VIP_LOG"
chown "$VIP_USER:wheel" "$VIP_RUN"
[ -f "$VIP_ETC/config.yaml" ] || { cp "$PROJECT_DIR/examples/config.yaml" "$VIP_ETC/config.yaml"; chmod 600 "$VIP_ETC/config.yaml"; chown root:wheel "$VIP_ETC/config.yaml"; }
echo "  ✅ 目录就绪"

# ── 5. 自启动（Watchdog + Login Items，避免 launchd macOS 26 bug）──
echo ""
echo "⚙️  配置自启动..."

# 5a. 创建 watchdog 脚本
WATCHDOG="$HERMES_HOME/scripts/hermes-vipd-watchdog.sh"
sudo -u "$REAL_USER" mkdir -p "$(dirname "$WATCHDOG")"
sudo -u "$REAL_USER" cat > "$WATCHDOG" << WDS
#!/bin/bash
# Hermes VIP Daemon Watchdog — 自启动 + 自动恢复
LOCKFILE="/tmp/hermes-vipd-watchdog.lock"
PIDFILE="/tmp/hermes-vipd.pid"
LOG="/tmp/hermes-vipd-watchdog.log"

# 防重复启动
if [ -f "\$LOCKFILE" ]; then
    OLD=\$(cat "\$LOCKFILE" 2>/dev/null)
    if ps -p "\$OLD" >/dev/null 2>&1; then exit 0; fi
fi
echo \$\$ > "\$LOCKFILE"
trap 'rm -f "\$PIDFILE" "\$LOCKFILE"' EXIT

start_daemon() {
    echo "\$(date) Starting VIP daemon..." >> "\$LOG"
    cd /tmp
    HOME=/var/empty sudo -u $VIP_USER $VIP_BIN 2>>"\$LOG" &
    echo \$! > "\$PIDFILE"
}

start_daemon
while true; do
    PID=\$(cat "\$PIDFILE" 2>/dev/null)
    if [ -z "\$PID" ] || ! ps -p "\$PID" >/dev/null 2>&1; then
        echo "\$(date) Daemon exited, restarting..." >> "\$LOG"
        sleep 3
        start_daemon
    fi
    sleep 10
done
WDS
chmod +x "$WATCHDOG"
echo "  ✅ watchdog: $WATCHDOG"

# 5b. 添加为 Login Item
sudo -u "$REAL_USER" osascript -e "
tell application \"System Events\"
    if not (exists login item \"hermes-vipd\") then
        make login item at end with properties {path:\"$WATCHDOG\", hidden:true, name:\"hermes-vipd\"}
    end if
end tell
" 2>/dev/null || true
echo "  ✅ Login Item 已添加"

# 5c. 立即启动 watchdog
sudo -u "$REAL_USER" nohup "$WATCHDOG" >/dev/null 2>&1 &
sleep 2
echo "  ✅ 已启动"

# ── 6. Plugin ──
PDIR="$HERMES_HOME/plugins/hermes-vip"
rm -rf "$PDIR" 2>/dev/null || true
sudo -u "$REAL_USER" mkdir -p "$PDIR"
sudo -u "$REAL_USER" cp "$PROJECT_DIR/hermes-plugin/"* "$PDIR/"
rm -rf "$PDIR/__pycache__" 2>/dev/null || true
HBIN="$HERMES_BIN"
[ -x "$HBIN" ] || HBIN=$(sudo -u "$REAL_USER" which hermes 2>/dev/null || echo "")
if [ -x "$HBIN" ]; then
    echo n | sudo -u "$REAL_USER" "$HBIN" plugins enable hermes-vip 2>/dev/null && \
        echo "  ✅ Plugin 已启用" || \
        echo "  ⚠️  Plugin 手动启用: $HBIN plugins enable hermes-vip"
fi

# ── 7. 验证 ──
echo ""
sleep 2
if [ -S "$VIP_RUN/control.sock" ]; then
    echo -e "  ${GREEN}✅ daemon 运行中${NC}"
else
    echo -e "  ${YELLOW}⚠️  正在启动，5秒后检查...${NC}"
    sleep 5
    [ -S "$VIP_RUN/control.sock" ] && echo -e "  ${GREEN}✅ daemon 运行中${NC}" || echo -e "  ${YELLOW}⚠️  手动: sudo $VIP_BIN &${NC}"
fi

echo ""
echo "┌─────────────────────────────────────────────┐"
echo "│  ${GREEN}✅ 安装完成${NC}                                  │"
echo "│                                             │"
echo "│  Login Item: hermes-vipd（重启自动启动）       │"
echo "│  管理: tail /tmp/hermes-vipd-watchdog.log    │"
echo "│  重启 Hermes Desktop 使 Plugin 生效          │"
echo "└─────────────────────────────────────────────┘"
echo ""
echo -e "${GREEN}✅ 安装完成 — 重启 Hermes Desktop 生效${NC}"
