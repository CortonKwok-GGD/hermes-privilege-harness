#!/bin/bash
# ==============================================================================
# Hermes VIP — Linux 安装脚本 (Debian/Ubuntu)
# ==============================================================================
# 用法:
#   chmod +x install-linux.sh
#   sudo ./install-linux.sh
#
# 作用:
#   1. 安装 VIP daemon 到 /usr/local/bin/hermes-vipd
#   2. 创建 /etc/hermes-vip/ 配置文件目录（root:700）
#   3. 创建 socket 目录 /var/run/hermes-vip/
#   4. 创建审计日志目录 /var/log/hermes-vip/
#   5. 配置 systemd service
#   6. 启动 VIP daemon
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "┌─────────────────────────────────────────────┐"
echo "│  Hermes VIP — Linux 安装                    │"
echo "└─────────────────────────────────────────────┘"
echo ""

# ── 检查 root ──
if [ "$EUID" -ne 0 ]; then
    echo "❌ 必须以 root 身份运行: sudo $0"
    exit 1
fi

# ── 检查 systemd ──
if ! command -v systemctl &>/dev/null; then
    echo "❌ 未检测到 systemd，此脚本仅支持 systemd 发行版"
    exit 1
fi

# ── 检查 Python3 ──
PYTHON=""
for cmd in python3 python3.11 python3.10; do
    if command -v $cmd &>/dev/null; then
        PYTHON=$(command -v $cmd)
        break
    fi
done
if [ -z "$PYTHON" ]; then
    echo "❌ 未找到 Python 3，请先安装: apt install python3"
    exit 1
fi
echo "  ✅ Python: $PYTHON ($($PYTHON --version 2>&1))"

# ── 配置 ──
VIP_BIN="/usr/local/bin/hermes-vipd"
VIP_LIB="/usr/local/lib/hermes-vip"
VIP_ETC="/etc/hermes-vip"
VIP_RUN="/run/hermes-vip"
VIP_LOG="/var/log/hermes-vip"
VIP_SERVICE="/etc/systemd/system/hermes-vipd.service"

# ── Step 1: 安装 daemon ──
echo ""
echo "📦 安装 VIP daemon..."
mkdir -p "$VIP_LIB"
# 复制整个 daemon 和 connectors 包
cp -r "$PROJECT_DIR/daemon/" "$VIP_LIB/daemon/"
cp -r "$PROJECT_DIR/connectors/" "$VIP_LIB/connectors/"

# 创建入口脚本
cat > "$VIP_BIN" << LAUNCHER
#!/bin/bash
export PYTHONPATH="$VIP_LIB:\$PYTHONPATH"
exec $PYTHON -m daemon.vipd "\$@"
LAUNCHER
chmod +x "$VIP_BIN"
echo "  ✅ $VIP_BIN"

# ── Step 2: 配置目录 ──
echo ""
echo "📁 创建配置目录..."
mkdir -p "$VIP_ETC"
chmod 700 "$VIP_ETC"
chown root:root "$VIP_ETC"
echo "  ✅ $VIP_ETC (root:root 700)"

if [ ! -f "$VIP_ETC/config.yaml" ]; then
    cp "$PROJECT_DIR/examples/config.yaml" "$VIP_ETC/config.yaml"
    chmod 600 "$VIP_ETC/config.yaml"
    chown root:root "$VIP_ETC/config.yaml"
    echo "  ✅ $VIP_ETC/config.yaml"
else
    echo "  ⏭  config.yaml 已存在，跳过"
fi

# ── Step 3: 日志目录（socket 目录由 systemd RuntimeDirectory 自动创建）──
echo ""
echo "🔌 创建日志目录..."
mkdir -p "$VIP_LOG"
chmod 755 "$VIP_LOG"
chown root:root "$VIP_LOG"
echo "  ✅ $VIP_LOG"

# ── Step 4: systemd service ──
echo ""
echo "⚙️  配置 systemd..."
cp "$PROJECT_DIR/examples/hermes-vipd.service" "$VIP_SERVICE"
chmod 644 "$VIP_SERVICE"
chown root:root "$VIP_SERVICE"
echo "  ✅ $VIP_SERVICE"

# ── Step 5: 重载 systemd 并启动 ──
echo ""
echo "🚀 启动 VIP daemon..."
systemctl daemon-reload
systemctl enable hermes-vipd
systemctl start hermes-vipd
sleep 2

# 验证
if systemctl is-active --quiet hermes-vipd; then
    echo "  ✅ VIP daemon 运行中"
    echo "  📍 PID: $(systemctl show -p MainPID hermes-vipd | cut -d= -f2)"
    echo "  📍 request socket: $VIP_RUN/request.sock"
    echo "  📍 control socket: $VIP_RUN/control.sock"
    echo ""
    echo "  📋 查看状态: systemctl status hermes-vipd"
    echo "  📋 查看日志: journalctl -u hermes-vipd -f"
    echo "  ⛔ 停止:     systemctl stop hermes-vipd"
    echo "  🔄 重启:     systemctl restart hermes-vipd"
else
    echo "  ⚠️  daemon 启动失败，检查日志:"
    echo "     journalctl -u hermes-vipd --no-pager -n 30"
fi

echo ""
echo "┌─────────────────────────────────────────────┐"
echo "│  ✅ 安装完成                                  │"
echo "│                                             │"
echo "│  管理命令:                                   │"
echo "│    systemctl status hermes-vipd             │"
echo "│    journalctl -u hermes-vipd -f             │"
echo "│    systemctl restart hermes-vipd            │"
echo "│                                             │"
echo "│  安装 Hermes Plugin:                        │"
echo "│    cp -r hermes-plugin ~/.hermes/plugins/   │"
echo "│    # 重启 Hermes                            │"
echo "│                                             │"
echo "│  配置文件: $VIP_ETC/config.yaml              │"
echo "└─────────────────────────────────────────────┘"
