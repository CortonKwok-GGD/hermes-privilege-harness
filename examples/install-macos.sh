#!/bin/bash
# ==============================================================================
# Hermes VIP — macOS 安装脚本
# ==============================================================================
# 用法:
#   chmod +x install-macos.sh
#   sudo ./install-macos.sh
#
# 作用:
#   1. 安装 VIP daemon 到 /usr/local/bin/hermes-vipd
#   2. 创建 /etc/hermes-vip/ 配置文件目录（root:wheel 700）
#   3. 配置 launchd plist
#   4. 创建 socket 目录 /var/run/hermes-vip/
#   5. 创建审计日志目录 /var/log/hermes-vip/
#   6. 启动 VIP daemon
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "┌─────────────────────────────────────────────┐"
echo "│  Hermes VIP — macOS 安装                     │"
echo "└─────────────────────────────────────────────┘"
echo ""

# ── 检查 root ──
if [ "$EUID" -ne 0 ]; then
    echo "❌ 必须以 root 身份运行: sudo $0"
    exit 1
fi

# ── 配置 ──
VIP_BIN="/usr/local/bin/hermes-vipd"
VIP_ETC="/etc/hermes-vip"
VIP_RUN="/var/run/hermes-vip"
VIP_LOG="/var/log/hermes-vip"
VIP_PLIST="/Library/LaunchDaemons/com.hermes.vipd.plist"

# ── Step 1: 安装 daemon ──
echo "📦 安装 VIP daemon..."
cp "$PROJECT_DIR/daemon/vipd.py" "$VIP_BIN"
# 复制整个 daemon 包
mkdir -p /usr/local/lib/hermes-vip/
cp -r "$PROJECT_DIR/daemon/" /usr/local/lib/hermes-vip/daemon/
cp -r "$PROJECT_DIR/connectors/" /usr/local/lib/hermes-vip/connectors/
chmod +x "$VIP_BIN"
echo "  ✅ $VIP_BIN"

# ── Step 2: 配置目录 ──
echo "📁 创建配置目录..."
mkdir -p "$VIP_ETC"
chmod 700 "$VIP_ETC"
chown root:wheel "$VIP_ETC"
echo "  ✅ $VIP_ETC (root:wheel 700)"

if [ ! -f "$VIP_ETC/config.yaml" ]; then
    cp "$PROJECT_DIR/examples/config.yaml" "$VIP_ETC/config.yaml"
    chmod 600 "$VIP_ETC/config.yaml"
    chown root:wheel "$VIP_ETC/config.yaml"
    echo "  ✅ $VIP_ETC/config.yaml"
else
    echo "  ⏭  config.yaml 已存在，跳过"
fi

# ── Step 3: socket 和日志目录 ──
echo "🔌 创建运行时目录..."
mkdir -p "$VIP_RUN"
chmod 700 "$VIP_RUN"
chown root:wheel "$VIP_RUN"
echo "  ✅ $VIP_RUN (root:wheel 700)"

mkdir -p "$VIP_LOG"
chmod 755 "$VIP_LOG"
chown root:wheel "$VIP_LOG"
echo "  ✅ $VIP_LOG"

# ── Step 4: launchd plist ──
echo "⚙️  配置 launchd..."
cp "$PROJECT_DIR/examples/com.hermes.vipd.plist" "$VIP_PLIST"
chmod 644 "$VIP_PLIST"
chown root:wheel "$VIP_PLIST"
echo "  ✅ $VIP_PLIST"

# ── Step 5: 修正 plist 中的可执行路径 ──
# TODO: 实际部署时需要将 vipd.py 打包为一个可执行入口
# 临时方案：用 shell 包装器
cat > /usr/local/bin/hermes-vipd-launcher.sh << 'LAUNCHER'
#!/bin/bash
export PYTHONPATH="/usr/local/lib/hermes-vip:$PYTHONPATH"
exec python3 /usr/local/lib/hermes-vip/daemon/vipd.py
LAUNCHER
chmod +x /usr/local/bin/hermes-vipd-launcher.sh

# ── Step 6: 启动 ──
echo "🚀 启动 VIP daemon..."
launchctl load "$VIP_PLIST" 2>/dev/null || true
sleep 1

# 验证
if [ -S "$VIP_RUN/control.sock" ]; then
    echo "  ✅ VIP daemon 运行中"
    echo "  📍 request socket: $VIP_RUN/request.sock"
    echo "  📍 control socket: $VIP_RUN/control.sock"
else
    echo "  ⚠️   daemon 可能尚未就绪，检查日志:"
    echo "     tail -20 $VIP_LOG/vipd.log"
fi

echo ""
echo "┌─────────────────────────────────────────────┐"
echo "│  ✅ 安装完成                                  │"
echo "│                                             │"
echo "│  管理命令:                                   │"
echo "│    launchctl start com.hermes.vipd          │"
echo "│    launchctl stop com.hermes.vipd           │"
echo "│    tail -f $VIP_LOG/vipd.log                │"
echo "│                                             │"
echo "│  安装 Hermes Plugin:                        │"
echo "│    cp -r hermes-plugin ~/.hermes/plugins/   │"
echo "│    # 重启 Hermes                            │"
echo "└─────────────────────────────────────────────┘"
