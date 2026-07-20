#!/bin/bash
# ==============================================================================
# Hermes VIP — macOS 安装脚本 v3.0
# 
# 安装目录: /usr/local/lib/hermes-vip/ (daemon 代码)
#          /usr/local/bin/hermes-vipd   (daemon 入口)
#          /etc/hermes-vip/            (配置)
#          /var/run/hermes-vip/        (socket)
#          /var/log/hermes-vip/        (日志)
#
# 开发目录: ~/hermes-workspace/apps/hermes-vip/
# 安装部署和开发完全分离，安装脚本从开发目录复制文件到系统目录。
# ==============================================================================
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "┌─────────────────────────────────────────────┐"
echo "│  Hermes VIP — macOS 安装 v3.0                │"
echo "└─────────────────────────────────────────────┘"
echo ""

[ "$EUID" -eq 0 ] || { echo -e "${RED}❌ 需要 sudo 运行: sudo bash install-macos.sh${NC}"; exit 1; }

# ── 检测真实用户 ──
REAL_USER="${SUDO_USER:-}"
[ -z "$REAL_USER" ] && REAL_USER="$(logname 2>/dev/null || echo '')"
[ -z "$REAL_USER" ] && REAL_USER="$(stat -f '%Su' /dev/console 2>/dev/null || echo '')"
[ -z "$REAL_USER" ] && REAL_USER="$(who am i 2>/dev/null | awk '{print $1}' || echo '')"
[ -z "$REAL_USER" ] && REAL_USER="$(ls -ld /Users/* 2>/dev/null | grep -v Shared | head -1 | awk '{print $3}')"

if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    echo -e "${RED}❌ 无法检测当前用户${NC}"
    echo "   手动: REAL_USER=你的用户名 sudo -E bash install-macos.sh"
    exit 1
fi

REAL_HOME="$(eval echo ~$REAL_USER)"
REAL_UID="$(id -u "$REAL_USER")"
HERMES_HOME="${HERMES_HOME:-$REAL_HOME/.hermes}"

echo "👤 $REAL_USER (uid=$REAL_UID, home=$REAL_HOME)"
echo "📦 Hermes home: $HERMES_HOME"

# ── Hermes 版本检测（>= 0.18.0 才支持原生审批卡片）──
MIN_HERMES="0.18.0"
hermes_version() { "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0"; }
version_gte() { printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 | grep -qx "$1"; }

HERMES_BIN=""
HERMES_VER="0.0.0"
for hbin in /opt/homebrew/bin/hermes /usr/local/bin/hermes "$(sudo -u "$REAL_USER" which hermes 2>/dev/null || echo '')"; do
    [ -x "$hbin" ] || continue
    v="$(hermes_version "$hbin")"
    [ "$v" != "0.0.0" ] && { HERMES_BIN="$hbin"; HERMES_VER="$v"; break; }
done

if [ -z "$HERMES_BIN" ]; then
    echo -e "${RED}❌ 未找到 Hermes 二进制${NC}"; exit 1
fi

if ! version_gte "$HERMES_VER" "$MIN_HERMES"; then
    echo -e "${RED}❌ Hermes $HERMES_VER < $MIN_HERMES（不支持原生审批卡片）${NC}"
    exit 1
fi
echo "🆗 Hermes $HERMES_VER ($HERMES_BIN)"

# ── 配置 ──
VIP_USER="_hermesvip"
VIP_BIN="/usr/local/bin/hermes-vipd"
VIP_LIB="/usr/local/lib/hermes-vip"
VIP_ETC="/etc/hermes-vip"
VIP_RUN="/var/run/hermes-vip"
VIP_LOG="/var/log/hermes-vip"
VIP_WATCHDOG="$HERMES_HOME/scripts/hermes-vipd-watchdog.sh"
LABEL="com.hermes.vipd"

# ── 0. 清理旧部署 ──
echo ""
echo "🧹 清理旧部署..."

# 0a. 停 daemon
pkill -f "hermes-vipd" 2>/dev/null || true
pkill -f "daemon.vipd" 2>/dev/null || true
pkill -f "hermes-vipd-watchdog" 2>/dev/null || true
sleep 1

# 0b. 清理废弃的 launchd plist（已改用 Login Items + watchdog）
for plist in \
    "/Library/LaunchDaemons/$LABEL.plist" \
    "/Library/LaunchAgents/$LABEL.plist"; do
    [ -f "$plist" ] && { rm -f "$plist"; echo "  🗑 清理 $plist"; }
done

# 0c. 清理旧 socket
rm -f "$VIP_RUN/request.sock" "$VIP_RUN/control.sock" 2>/dev/null || true

echo "  ✅ 清理完成"

# ── 1. _hermesvip 用户 ──
echo ""
echo "👤 配置 $VIP_USER 用户..."
if ! id "$VIP_USER" &>/dev/null; then
    U=498
    while dscl . -list /Users UniqueID | awk '{print $2}' | grep -qx "$U"; do U=$((U-1)); done
    dscl . -create "/Users/$VIP_USER" UniqueID "$U"
    dscl . -create "/Users/$VIP_USER" UserShell "/usr/bin/false"
    dscl . -create "/Users/$VIP_USER" RealName "Hermes VIP Daemon"
    dscl . -create "/Users/$VIP_USER" NFSHomeDirectory "/var/empty"
    dscl . -create "/Users/$VIP_USER" PrimaryGroupID 1
    echo "  ✅ $VIP_USER 创建 (uid=$U)"
else
    echo "  ⏭  $VIP_USER 已存在"
fi

# 1a. 清理多余组成员
for grp in _lpoperator localaccounts "com.apple.sharepoint.group.1"; do
    dseditgroup -o edit -d "$VIP_USER" -t user "$grp" 2>/dev/null && \
        echo "  🧹 移除组: $grp" || true
done
echo "  ✅ 组成员已最小化"

# ── 2. sudoers ──
echo ""
echo "🔐 配置 sudoers..."
S="/etc/sudoers.d/$VIP_USER"
if [ ! -f "$S" ]; then
    echo "# VIP daemon — NOPASSWD 是有意设计: 安全边界在审批卡+stamp 验证,不在 sudoers 命令白名单" > "$S"
    echo "$VIP_USER ALL=(ALL) NOPASSWD: ALL" >> "$S"
    chmod 440 "$S"; chown root:wheel "$S"
    echo "  ✅ _hermesvip sudoers"
else
    echo "  ⏭  已存在"
fi

# ── 2b. _hermes sandbox sudoers ──
echo ""
echo "🔐 配置 _hermes sandbox sudoers..."
SB_USER="_hermes"
if id "$SB_USER" &>/dev/null; then
    SB_S="/etc/sudoers.d/hermes-sandbox"
    if [ ! -f "$SB_S" ]; then
        echo "# _hermes sandbox user — NOPASSWD: only _hermes target, not root" > "$SB_S"
        echo "$REAL_USER ALL=($SB_USER) NOPASSWD: ALL" >> "$SB_S"
        chmod 440 "$SB_S"; chown root:wheel "$SB_S"
        echo "  ✅ $REAL_USER → $SB_USER NOPASSWD"
    else
        echo "  ⏭  $SB_S 已存在"
    fi
else
    echo "  ⏭  _hermes 用户不存在，跳过"
fi

# watchdog / 用户需要 sudo -u _hermesvip 启动 daemon
D="/etc/sudoers.d/hermes-vipd-launch"
if [ ! -f "$D" ]; then
    echo "ALL ALL=($VIP_USER) NOPASSWD: $VIP_BIN" > "$D"
    chmod 440 "$D"; chown root:wheel "$D"
    echo "  ✅ launch sudoers"
else
    echo "  ⏭  已存在"
fi

# ── 3. mac 用户必须在 daemon 组（daemon 创建 socket 为 660）──
echo ""
echo "🔗 配置 socket 访问..."
if id -G "$REAL_USER" | tr ' ' '\n' | grep -qx '1'; then
    echo "  ✅ $REAL_USER 已在 daemon 组"
else
    echo -e "${YELLOW}⚠️  $REAL_USER 不在 daemon 组，socket 将无法连接${NC}"
    echo "  执行: sudo dseditgroup -o edit -a $REAL_USER -t user daemon"
    echo "  然后重新运行本脚本"
    exit 1
fi

# ── 4. 安装 daemon ──
echo ""
echo "📦 安装 daemon..."

# 4a. daemon 代码
rm -rf "$VIP_LIB" 2>/dev/null || true
mkdir -p "$VIP_LIB/daemon" "$VIP_LIB/connectors"
cp "$PROJECT_DIR/daemon/"*.py "$VIP_LIB/daemon/"
cp "$PROJECT_DIR/connectors/"*.py "$VIP_LIB/connectors/"
touch "$VIP_LIB/__init__.py"
chmod -R 755 "$VIP_LIB"
chown -R root:wheel "$VIP_LIB"
echo "  ✅ daemon 代码: $VIP_LIB"

# 4b. daemon wrapper (Python 3.9 系统自带，只用 stdlib)
cat > "$VIP_BIN" << 'LB'
#!/bin/bash
# Hermes VIP Daemon wrapper
# 用系统 Python 3.9 运行，只依赖 stdlib，不需要额外 venv
export PYTHONPATH="/usr/local/lib/hermes-vip:$PYTHONPATH"
cd /tmp  # daemon 不需要特定工作目录
HOME=/var/empty
exec /usr/bin/python3 -m daemon.vipd "$@"
LB
chmod 755 "$VIP_BIN"; chown root:wheel "$VIP_BIN"
echo "  ✅ daemon 入口: $VIP_BIN"

# ── 5. 目录 ──
mkdir -p "$VIP_ETC" "$VIP_RUN" "$VIP_LOG"
chmod 755 "$VIP_ETC" "$VIP_RUN" "$VIP_LOG"
chown root:wheel "$VIP_ETC"
chown "$VIP_USER:daemon" "$VIP_RUN" "$VIP_LOG"
[ -f "$VIP_ETC/config.yaml" ] || {
    cp "$PROJECT_DIR/examples/config.yaml" "$VIP_ETC/config.yaml"
    chmod 600 "$VIP_ETC/config.yaml"
    chown root:wheel "$VIP_ETC/config.yaml"
}
echo "  ✅ 目录就绪"

# ── 5b. Blocklist ──
BLOCKLIST_FILE="/usr/local/etc/hermes-vip/blocklist.yaml"
mkdir -p "$(dirname "$BLOCKLIST_FILE")"
if [ ! -f "$BLOCKLIST_FILE" ]; then
    cp "$PROJECT_DIR/examples/blocklist.yaml" "$BLOCKLIST_FILE"
    chmod 640 "$BLOCKLIST_FILE"
    chown root:daemon "$BLOCKLIST_FILE" 2>/dev/null || chown root:wheel "$BLOCKLIST_FILE"
    echo "  ✅ blocklist: $BLOCKLIST_FILE"
fi

# ── 6. 自启动（Watchdog + Login Items）──
echo ""
echo "⚙️  配置自启动..."

sudo -u "$REAL_USER" mkdir -p "$(dirname "$VIP_WATCHDOG")"

# 从模板生成 watchdog（替换占位符为实际路径）
sed -e "s|__VIP_BIN__|$VIP_BIN|g" \
    -e "s|__VIP_USER__|$VIP_USER|g" \
    -e "s|__VIP_RUN__|$VIP_RUN|g" \
    "$PROJECT_DIR/examples/hermes-vipd-watchdog.sh" | \
    sudo -u "$REAL_USER" tee "$VIP_WATCHDOG" > /dev/null
chmod +x "$VIP_WATCHDOG"
echo "  ✅ watchdog: $VIP_WATCHDOG"

# 移除旧的 Login Item（如果存在）
sudo -u "$REAL_USER" osascript -e "
tell application \"System Events\"
    try
        delete login item \"hermes-vipd\"
    end try
end tell
" 2>/dev/null || true

# ── Login Item 方案：macOS Login Items 对 .sh 文件不自动执行 ──
# 改用 AppleScript .app 包装 — 系统原生支持，无需额外权限
VIP_APP_DIR="$HERMES_HOME/apps"
sudo -u "$REAL_USER" mkdir -p "$VIP_APP_DIR"

# 创建 AppleScript applet 启动 watchdog
osacompile -o "$VIP_APP_DIR/hermes-vipd-watchdog.app" -e "
do shell script \"nohup $VIP_WATCHDOG >/dev/null 2>&1 &\"
" 2>/dev/null && echo "  ✅ .app 已编译" || {
    # 如果 osacompile 不可用（CLT 未装），退回到用 open 调脚本
    echo "  ⚠️  osacompile 不可用，改用 open 启动"
    sudo -u "$REAL_USER" osascript -e "
    tell application \"System Events\"
        make login item at end with properties {path:\"$VIP_WATCHDOG\", hidden:true, name:\"hermes-vipd\"}
    end tell
    " 2>/dev/null
}

# 如果可以编译了 .app，用它作为 Login Item
if [ -d "$VIP_APP_DIR/hermes-vipd-watchdog.app" ]; then
    sudo -u "$REAL_USER" osascript -e "
    tell application \"System Events\"
        make login item at end with properties {path:\"$VIP_APP_DIR/hermes-vipd-watchdog.app\", hidden:true, name:\"hermes-vipd\"}
    end tell
    " 2>/dev/null
fi
echo "  ✅ Login Item 已添加"

# 立即启动 watchdog
sudo -u "$REAL_USER" nohup "$VIP_WATCHDOG" >/dev/null 2>&1 &
sleep 1
echo "  ✅ watchdog 已启动"

# ── 7. Plugin ──
echo ""
echo "🔌 安装 Plugin..."
PDIR="$HERMES_HOME/plugins/hermes-vip"
rm -rf "$PDIR" 2>/dev/null || true
sudo -u "$REAL_USER" mkdir -p "$PDIR"
sudo -u "$REAL_USER" cp "$PROJECT_DIR/hermes-plugin/"* "$PDIR/"
rm -rf "$PDIR/__pycache__" 2>/dev/null || true
echo "  ✅ Plugin 文件: $PDIR"

if [ -x "$HERMES_BIN" ]; then
    echo n | sudo -u "$REAL_USER" "$HERMES_BIN" plugins enable hermes-vip 2>/dev/null && \
        echo "  ✅ Plugin 已启用" || \
        echo "  ⚠️  手动: $HERMES_BIN plugins enable hermes-vip"
fi

# ── 8. 等待 daemon 就绪后设 socket 权限 ──
echo ""
echo "⏳ 等待 daemon 就绪..."
for i in $(seq 1 15); do
    [ -S "$VIP_RUN/request.sock" ] && break
    sleep 0.5
done

if [ -S "$VIP_RUN/request.sock" ]; then
    echo "  ✅ daemon 运行中，socket 权限: 660 $VIP_USER:daemon"
else
    echo -e "  ${YELLOW}⚠️  daemon 未在预期时间内启动${NC}"
    echo "  手动检查: ls -la $VIP_RUN/"
    echo "  手动启动: sudo -u $VIP_USER $VIP_BIN &"
fi


# ── 9. Workspace .git 权限（Docker 终端兼容）──
# Hermes Docker 后台以 _hermes 用户运行，需能读写 workspace 下 git 仓库。
# 不影响 ~/.hermes/ 的权限控制。
echo ""
echo "🔗 配置 workspace .git 共享..."
WS_GROUP="hermes-shared"

# 创建共享组（不存在则创建）
if ! getent group "$WS_GROUP" &>/dev/null; then
    groupadd -f "$WS_GROUP" 2>/dev/null || pw groupadd "$WS_GROUP" 2>/dev/null || true
fi

# 加真实用户到共享组
usermod -a -G "$WS_GROUP" "$REAL_USER" 2>/dev/null || \
    dseditgroup -o edit -a "$REAL_USER" -t user "$WS_GROUP" 2>/dev/null || true

# 加 _hermes（如果存在）到共享组
if id "_hermes" &>/dev/null; then
    usermod -a -G "$WS_GROUP" _hermes 2>/dev/null || \
        dseditgroup -o edit -a _hermes -t user "$WS_GROUP" 2>/dev/null || true
    SHARED_MSG="_hermes + $REAL_USER"
else
    SHARED_MSG="$REAL_USER（_hermes 不存在，跳过）"
fi

# 设置 workspace 下所有 .git 目录的组权限（不碰 ~/.hermes/）
WS_DIR="$REAL_HOME/hermes-workspace"
if [ -d "$WS_DIR" ]; then
    find "$WS_DIR" -name ".git" -type d -not -path "*/.hermes/*" 2>/dev/null | while read gd; do
        chgrp -R "$WS_GROUP" "$gd" 2>/dev/null || true
        chmod -R g+rwX "$gd" 2>/dev/null || true
    done
    echo "  ✅ workspace .git 权限已配置（$SHARED_MSG）"
else
    echo "  ⏭  $WS_DIR 不存在，跳过"
fi

echo ""
echo "┌─────────────────────────────────────────────┐"
echo "│  ${GREEN}✅ Hermes VIP v8.0 安装完成${NC}                  │"
echo "│                                             │"
echo "│  ⚠️  沙箱功能 (bwrap) 当前仅 Linux              │"
echo "│  macOS sandbox-exec 支持待实现                 │"
echo "│  自启动: Login Items（重启自动启动）             │"
echo "│  日志: tail /tmp/hermes-vipd-watchdog.log    │"
echo "│  daemon 日志: tail $VIP_LOG/vipd.log         │"
echo "│  重启 Hermes Desktop 使 Plugin 生效          │"
echo "└─────────────────────────────────────────────┘"
