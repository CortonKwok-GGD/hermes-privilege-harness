#!/bin/bash
# ==============================================================================
# Hermes VIP — Linux 安装脚本 v3.0 (systemd)
#
# 安装目录: /usr/local/lib/hermes-vip/ (daemon 代码)
#          /usr/local/bin/hermes-vipd   (daemon 入口)
#          /etc/hermes-vip/            (配置)
#          /run/hermes-vip/            (socket, systemd RuntimeDirectory)
#          /var/log/hermes-vip/        (日志)
#
# 开发目录: ~/hermes-workspace/apps/hermes-vip/
# ==============================================================================
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "┌─────────────────────────────────────────────┐"
echo "│  Hermes VIP — Linux 安装 v3.0               │"
echo "└─────────────────────────────────────────────┘"
echo ""

[ "$(uname)" = "Linux" ] || { echo -e "${RED}❌ 仅支持 Linux${NC}"; exit 1; }
[ "$EUID" -eq 0 ] || { echo -e "${RED}❌ 需要 root: sudo bash install-linux.sh${NC}"; exit 1; }

# ── 检测真实用户 ──
REAL_USER="${SUDO_USER:-}"
[ -z "$REAL_USER" ] && REAL_USER="$(logname 2>/dev/null || echo '')"
[ -z "$REAL_USER" ] && REAL_USER="$(who am i 2>/dev/null | awk '{print $1}' || echo '')"
[ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ] && {
    echo -e "${RED}❌ 无法检测当前用户${NC}"
    echo "   手动: REAL_USER=用户名 sudo -E bash install-linux.sh"
    exit 1
}
REAL_HOME="$(eval echo ~$REAL_USER)"
HERMES_HOME="${HERMES_HOME:-$REAL_HOME/.hermes}"
echo "👤 $REAL_USER (home=$REAL_HOME)"
echo "📦 Hermes home: $HERMES_HOME"

# ── Hermes 版本检测 ──
MIN_HERMES="0.18.0"
hermes_version() { "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0"; }
version_gte() { printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 | grep -qx "$1"; }

HERMES_BIN="$(sudo -u "$REAL_USER" which hermes 2>/dev/null || echo "$HERMES_HOME/bin/hermes")"
HERMES_VER="$(hermes_version "$HERMES_BIN")"
if ! version_gte "$HERMES_VER" "$MIN_HERMES"; then
    echo -e "${RED}❌ Hermes $HERMES_VER < $MIN_HERMES（不支持原生审批卡片）${NC}"
    exit 1
fi
echo "🆗 Hermes $HERMES_VER ($HERMES_BIN)"

# ── 配置 ──
VIP_USER="hermes-vip"
VIP_BIN="/usr/local/bin/hermes-vipd"
VIP_LIB="/usr/local/lib/hermes-vip"
VIP_ETC="/etc/hermes-vip"
VIP_RUN="/run/hermes-vip"
VIP_LOG="/var/log/hermes-vip"
VIP_SERVICE="hermes-vipd"

# ── 0. 清理旧部署 ──
echo ""
echo "🧹 清理旧部署..."
systemctl stop "$VIP_SERVICE" 2>/dev/null || true
systemctl disable "$VIP_SERVICE" 2>/dev/null || true
pkill -f "hermes-vipd" 2>/dev/null || true
pkill -f "daemon.vipd" 2>/dev/null || true
sleep 1
rm -f "$VIP_RUN/request.sock" "$VIP_RUN/control.sock" 2>/dev/null || true
# 清理旧版 macOS launchd plist（如果跨平台同步过来的）
rm -f /Library/LaunchDaemons/com.hermes.vipd.plist /Library/LaunchAgents/com.hermes.vipd.plist 2>/dev/null || true
# 清理旧版 sandbox 引用
rm -f /usr/local/bin/hermes-sandbox 2>/dev/null || true
echo "  ✅ 清理完成"

# ── 0.5 沙箱依赖 ──
echo ""
echo "📦 安装沙箱依赖 (bwrap)..."
if command -v bwrap &>/dev/null; then
    echo "  ⏭  bwrap 已安装"
else
    apt-get install -y bubblewrap 2>/dev/null && echo "  ✅ bwrap 已安装" || \
        echo "  ⚠️  bwrap 安装失败，沙箱功能不可用"
fi

# ── 1. hermes-vip 用户 ──
echo ""
echo "👤 配置 $VIP_USER 用户..."
if ! id "$VIP_USER" &>/dev/null; then
    useradd -r -s /sbin/nologin -d /var/empty -c "Hermes VIP Daemon" "$VIP_USER"
    echo "  ✅ $VIP_USER 创建"
else
    # 确保 shell 正确
    usermod -s /sbin/nologin "$VIP_USER" 2>/dev/null || true
    echo "  ⏭  $VIP_USER 已存在，shell 已设为 /sbin/nologin"
fi
echo "  ✅ 组成员已最小化"

# ── 2. sudoers ──
echo ""
echo "🔐 配置 sudoers..."
S="/etc/sudoers.d/$VIP_USER"
if [ ! -f "$S" ]; then
    echo "# VIP daemon — NOPASSWD 是有意设计: 安全边界在审批卡+stamp 验证,不在 sudoers 命令白名单" > "$S"
    echo "$VIP_USER ALL=(ALL) NOPASSWD: ALL" >> "$S"
    chmod 440 "$S"
    echo "  ✅ hermes-vip sudoers"
else
    echo "  ⏭  已存在"
fi

# ── 2b. _hermes sandbox 用户 sudoers ──
echo ""
echo "🔐 配置 _hermes sandbox sudoers..."
SB_USER="_hermes"
if id "$SB_USER" &>/dev/null; then
    SB_S="/etc/sudoers.d/hermes-sandbox"
    if [ ! -f "$SB_S" ]; then
        echo "# _hermes sandbox user — NOPASSWD: only _hermes target, not root" > "$SB_S"
        echo "$REAL_USER ALL=($SB_USER) NOPASSWD: ALL" >> "$SB_S"
        chmod 440 "$SB_S"
        echo "  ✅ $REAL_USER → $SB_USER NOPASSWD"
    else
        echo "  ⏭  $SB_S 已存在"
    fi
    # iptables 规则开机自启
    SB_UID=$(id -u "$SB_USER")
    if command -v iptables &>/dev/null; then
        iptables-save 2>/dev/null | grep -q "uid.*$SB_UID" || \
            echo "  ⚠️  需手动添加 iptables 规则: iptables -A OUTPUT -m owner --uid-owner $SB_UID -j DROP"
    fi
else
    echo "  ⏭  _hermes 用户不存在，跳过"
fi

# ── 3. Socket 访问 ──
echo ""
echo "🔗 配置 socket 访问..."
VIP_GID=$(id -g "$VIP_USER")
if ! id -nG "$REAL_USER" | tr ' ' '\n' | grep -qx "$VIP_GID\|$VIP_USER"; then
    # 把真实用户加入 hermes-vip 的组以便连接 socket
    usermod -a -G "$VIP_USER" "$REAL_USER" 2>/dev/null && \
        echo "  ✅ $REAL_USER 已加入 $VIP_USER 组" || \
        echo "  ⚠️  手动: usermod -a -G $VIP_USER $REAL_USER"
else
    echo "  ✅ $REAL_USER 已在 $VIP_USER 组"
fi

# ── 4. 安装 daemon ──
echo ""
echo "📦 安装 daemon..."
rm -rf "$VIP_LIB" 2>/dev/null || true
mkdir -p "$VIP_LIB/daemon" "$VIP_LIB/connectors"
cp "$PROJECT_DIR/daemon/"*.py "$VIP_LIB/daemon/"
cp "$PROJECT_DIR/connectors/"*.py "$VIP_LIB/connectors/"
touch "$VIP_LIB/__init__.py"
chmod -R 755 "$VIP_LIB"
echo "  ✅ daemon 代码: $VIP_LIB"

# Daemon wrapper
cat > "$VIP_BIN" << 'LB'
#!/bin/bash
export PYTHONPATH="/usr/local/lib/hermes-vip:$PYTHONPATH"
cd /tmp
HOME=/var/empty
exec python3 -m daemon.vipd "$@"
LB
chmod 755 "$VIP_BIN"
echo "  ✅ daemon 入口: $VIP_BIN"

# ── 5. 目录 ──
mkdir -p "$VIP_ETC" "$VIP_LOG"
chmod 755 "$VIP_ETC" "$VIP_LOG"
chown "root:$VIP_USER" "$VIP_LOG"
[ -f "$VIP_ETC/config.yaml" ] || {
    cp "$PROJECT_DIR/examples/config.yaml" "$VIP_ETC/config.yaml" 2>/dev/null || {
        # 如果 examples/config.yaml 不存在，生成最小配置
        cat > "$VIP_ETC/config.yaml" << 'MINCONF'
daemon:
  log_level: info
  audit_log: /var/log/hermes-vip/audit.log
sockets:
  request: /run/hermes-vip/request.sock
  control: /run/hermes-vip/control.sock
executor:
  timeout: 300
  max_stdout_bytes: 50000
MINCONF
    }
    chmod 644 "$VIP_ETC/config.yaml"
    chown "root:$VIP_USER" "$VIP_ETC/config.yaml"
}
echo "  ✅ 目录就绪"

# ── 5b. Blocklist ──
BLOCKLIST_FILE="/usr/local/etc/hermes-vip/blocklist.yaml"
mkdir -p "$(dirname "$BLOCKLIST_FILE")"
if [ ! -f "$BLOCKLIST_FILE" ]; then
    cp "$PROJECT_DIR/examples/blocklist.yaml" "$BLOCKLIST_FILE"
    chmod 640 "$BLOCKLIST_FILE" 2>/dev/null || chmod 644 "$BLOCKLIST_FILE"
    chown "root:$VIP_USER" "$BLOCKLIST_FILE" 2>/dev/null || chown root:root "$BLOCKLIST_FILE"
    echo "  ✅ blocklist: $BLOCKLIST_FILE"
fi

# ── 6. systemd 服务 ──
echo ""
echo "⚙️  注册 systemd 服务..."
cat > "/etc/systemd/system/$VIP_SERVICE.service" << SERVICE
[Unit]
Description=Hermes VIP Daemon
After=network.target

[Service]
Type=simple
User=$VIP_USER
Group=$VIP_USER
ExecStart=$VIP_BIN
Restart=always
RestartSec=5
RuntimeDirectory=hermes-vip
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable "$VIP_SERVICE"
systemctl start "$VIP_SERVICE"
echo "  ✅ systemd 服务已注册并启动"

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

# ── 8. 等待就绪 ──
echo ""
echo "⏳ 等待 daemon 就绪..."
sleep 2
for i in $(seq 1 10); do
    [ -S "$VIP_RUN/request.sock" ] && break
    sleep 0.5
done

if [ -S "$VIP_RUN/request.sock" ]; then
    echo "  ✅ daemon 运行中"
    ls -la "$VIP_RUN/request.sock"
else
    echo -e "  ${YELLOW}⚠️  daemon 未在预期时间内启动${NC}"
    echo "  检查: systemctl status $VIP_SERVICE"
    echo "  日志: journalctl -u $VIP_SERVICE -n 20"
fi

echo ""

# ── 9. Workspace 权限（Docker 终端兼容）──
# Hermes Docker 后台以 _hermes 用户运行。把整个 workspace 设成共享组，
# 确保能从 Docker 终端读写 git 仓库和代码文件。~/.hermes/ 不在此目录下，不受影响。
echo ""
echo "🔗 配置 workspace 共享组..."
WS_GROUP="hermes-shared"

if ! getent group "$WS_GROUP" &>/dev/null; then
    groupadd -f "$WS_GROUP" 2>/dev/null || pw groupadd "$WS_GROUP" 2>/dev/null || true
fi

usermod -a -G "$WS_GROUP" "$REAL_USER" 2>/dev/null || \
    dseditgroup -o edit -a "$REAL_USER" -t user "$WS_GROUP" 2>/dev/null || true
SHARED_MSG="$REAL_USER（_hermes 通过 ACL 控制，不加入共享组）"

WS_DIR="$REAL_HOME/hermes-workspace"
if [ -d "$WS_DIR" ]; then
    chgrp -R "$WS_GROUP" "$WS_DIR" 2>/dev/null
    chmod -R g+rwX "$WS_DIR" 2>/dev/null
    echo "  ✅ workspace 权限已配置（$SHARED_MSG）"
else
    echo "  ⏭  $WS_DIR 不存在，跳过"
fi
echo "┌─────────────────────────────────────────────┐"
echo "│  ${GREEN}✅ Hermes VIP v8.0 安装完成${NC}                   │"
echo "│                                             │"
echo "│  沙箱: bwrap (bubblewrap)                    │"
echo "│  sandbox.py + config.yaml 已部署              │"
echo "│  自启动: systemd (systemctl enable hermes-vipd) │"
echo "│  管理: systemctl status/restart hermes-vipd  │"
echo "│  日志: journalctl -u hermes-vipd -f          │"
echo "│                                             │"
echo "│  ⚠️  组变更: 如果 $REAL_USER 刚加入 $VIP_USER 组，    │"
echo "│     执行 newgrp $VIP_USER 或重新登录使组生效     │"
echo "│     然后重启 Hermes: hermes chat              │"
echo "└─────────────────────────────────────────────┘"

# 检测是否需要 newgrp
if ! id -nG "$REAL_USER" | tr ' ' '\n' | grep -qx "$VIP_USER"; then
    echo ""
    echo -e "${YELLOW}⚠️  $REAL_USER 不在 $VIP_USER 组！${NC}"
    echo "   Hermes 进程无法连接 daemon socket。"
    echo "   执行: newgrp $VIP_USER"
    echo "   然后重新启动 Hermes chat/desktop"
fi
