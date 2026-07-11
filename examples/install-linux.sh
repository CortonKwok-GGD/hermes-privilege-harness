#!/bin/bash
set -euo pipefail

# ==============================================================================
# Hermes VIP — 一行安装（Linux / macOS）
# ==============================================================================
# curl -fsSL https://hermes-vip.dev/install.sh | bash
# pip install hermes-vip
# ==============================================================================

echo "┌─────────────────────────────────────────────┐"
echo "│  Hermes VIP — 一行安装                      │"
echo "└─────────────────────────────────────────────┘"
echo ""

# ── 检测系统 ──
IS_MAC=false
IS_LINUX=false
case "$(uname)" in
  Darwin) IS_MAC=true ;;
  Linux)  IS_LINUX=true ;;
  *) echo "❌ 不支持的系统: $(uname)"; exit 1 ;;
esac

# ── 查找 Hermes ──
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
if [ ! -f "$HERMES_HOME/bin/hermes" ] && ! which hermes &>/dev/null; then
  echo "⚠ 未检测到 Hermes，请先安装: curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
  exit 1
fi
HERMES_BIN="${HERMES_BIN:-$(which hermes 2>/dev/null || echo $HERMES_HOME/bin/hermes)}"
echo "✅ Hermes: $($HERMES_BIN --version 2>&1 | head -1)"

# ── 确定项目路径（支持 pip 包和本地开发两种模式）──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)"

# ── 1. 装 Plugin ──
echo ""
echo "📦 安装 Hermes Plugin..."
mkdir -p "$HERMES_HOME/plugins/hermes-vip"
if [ -d "$PROJECT_DIR/hermes-plugin" ]; then
  cp "$PROJECT_DIR/hermes-plugin/"*.py "$PROJECT_DIR/hermes-plugin/plugin.yaml" "$HERMES_HOME/plugins/hermes-vip/" 2>/dev/null
else
  # pip 包模式：从包路径复制
  cp -r "$(python3 -c 'import hermes_vip; print(hermes_vip.__path__[0])' 2>/dev/null)/plugin/"* "$HERMES_HOME/plugins/hermes-vip/" 2>/dev/null || true
fi
echo "  ✅ $HERMES_HOME/plugins/hermes-vip/"

# ── 2. 启用 Plugin ──
echo ""
echo "🔌 启用 Plugin..."
# 直接写 config 启用
python3 << PYEOF 2>/dev/null || true
import json, os
path = os.path.expanduser("$HERMES_HOME/config.yaml")
import yaml
with open(path) as f:
    cfg = yaml.safe_load(f) or {}
plugins = cfg.setdefault('plugins', {})
enabled = plugins.setdefault('enabled', [])
if 'hermes-vip' not in enabled:
    enabled.append('hermes-vip')
with open(path, 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False)
PYEOF
echo "  ✅ Plugin 已启用"

# ── 3. 装 Daemon（需要 sudo）──
echo ""
echo "🔧 安装 VIP Daemon..."
if [ "$EUID" -ne 0 ]; then
  echo "  需要 root 权限安装 daemon"
  echo "  请执行: sudo $0"
  echo "  或在有 sudo 的终端运行: sudo bash $0"
else
  # ── 检测平台 ──
  if $IS_MAC; then
    # macOS launchd
    VIP_BIN="/usr/local/bin/hermes-vipd"
    VIP_LIB="/usr/local/lib/hermes-vip"
    VIP_ETC="/etc/hermes-vip"
    VIP_RUN="/var/run/hermes-vip"
    VIP_LOG="/var/log/hermes-vip"
    VIP_PLIST="/Library/LaunchDaemons/com.hermes.vipd.plist"

    mkdir -p "$VIP_LIB/daemon" "$VIP_LIB/connectors" "$VIP_ETC" "$VIP_RUN" "$VIP_LOG"
    chmod 755 "$VIP_RUN" "$VIP_ETC" "$VIP_LOG"

    # 复制代码
    cp "$PROJECT_DIR/daemon/"*.py "$VIP_LIB/daemon/"
    cp "$PROJECT_DIR/connectors/"*.py "$VIP_LIB/connectors/"
    echo '' > "$VIP_LIB/__init__.py"

    # 启动脚本
    cat > "$VIP_BIN" << 'LAUNCHER'
#!/bin/bash
export PYTHONPATH="/usr/local/lib/hermes-vip:$PYTHONPATH"
exec python3 -m daemon.vipd "$@"
LAUNCHER
    chmod +x "$VIP_BIN"

    # 配置
    cat > "$VIP_ETC/config.yaml" << CONF
trusted_user: $(logname 2>/dev/null || echo "$SUDO_USER")
sockets:
  request: $VIP_RUN/request.sock
  control: $VIP_RUN/control.sock
CONF
    chmod 600 "$VIP_ETC/config.yaml"

    # launchd plist
    cat > "$VIP_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.hermes.vipd</string>
<key>ProgramArguments</key><array><string>$VIP_BIN</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>UserName</key><string>root</string>
<key>StandardOutPath</key><string>$VIP_LOG/stdout.log</string>
<key>StandardErrorPath</key><string>$VIP_LOG/stderr.log</string>
</dict></plist>
PLIST
    chmod 644 "$VIP_PLIST"

    launchctl load "$VIP_PLIST" 2>/dev/null || true

  else
    # Linux systemd
    VIP_BIN="/usr/local/bin/hermes-vipd"
    VIP_LIB="/usr/local/lib/hermes-vip"
    VIP_ETC="/etc/hermes-vip"
    VIP_LOG="/var/log/hermes-vip"

    mkdir -p "$VIP_LIB/daemon" "$VIP_LIB/connectors" "$VIP_ETC" "$VIP_LOG"
    chmod 755 "$VIP_ETC" "$VIP_LOG"

    cp "$PROJECT_DIR/daemon/"*.py "$VIP_LIB/daemon/"
    cp "$PROJECT_DIR/connectors/"*.py "$VIP_LIB/connectors/"
    echo '' > "$VIP_LIB/__init__.py"

    cat > "$VIP_BIN" << 'LAUNCHER'
#!/bin/bash
export PYTHONPATH="/usr/local/lib/hermes-vip:$PYTHONPATH"
exec python3 -m daemon.vipd "$@"
LAUNCHER
    chmod +x "$VIP_BIN"

    cat > "$VIP_ETC/config.yaml" << CONF
trusted_user: ${SUDO_USER:-admin}
sockets:
  request: /run/hermes-vip/request.sock
  control: /run/hermes-vip/control.sock
CONF
    chmod 600 "$VIP_ETC/config.yaml"

    cat > /etc/systemd/system/hermes-vipd.service << SERVICE
[Unit]
Description=Hermes VIP Daemon
After=network.target
[Service]
Type=simple
User=root
ExecStart=$VIP_BIN
Restart=always
RuntimeDirectory=hermes-vip
RuntimeDirectoryMode=0755
[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable hermes-vipd
    systemctl start hermes-vipd
  fi

  sleep 2
  echo "  ✅ VIP Daemon 已启动"
fi

echo ""
echo "┌─────────────────────────────────────────────┐"
echo "│  ✅ 安装完成                                 │"
echo "│                                             │"
echo "│  重启 Hermes 后生效：                        │"
echo "│    hermes chat                              │"
echo "│    hermes desktop                           │"
echo "│                                             │"
echo "│  管理 VIP：                                  │"
echo "│    /vip-pending   查看待审批                 │"
echo "│    /vip-approve   批准请求                   │"
echo "│    /vip-deny      拒绝请求                   │"
echo "└─────────────────────────────────────────────┘"
