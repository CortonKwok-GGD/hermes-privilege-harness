#!/bin/bash
set -euo pipefail

echo "┌─────────────────────────────────────────────┐"
echo "│  Hermes VIP — 安装 / 升级                    │"
echo "└─────────────────────────────────────────────┘"
echo ""

# ── 检测系统 ──
IS_MAC=false
case "$(uname)" in Darwin) IS_MAC=true ;; Linux) ;; *) echo "❌ 不支持"; exit 1 ;; esac

# ── 找到真实用户（兼容 sudo 场景）──
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
REAL_HOME="$(eval echo ~$REAL_USER)"
HERMES_HOME="${HERMES_HOME:-$REAL_HOME/.hermes}"
HERMES_BIN="$(sudo -u $REAL_USER which hermes 2>/dev/null || echo $HERMES_HOME/bin/hermes)"
if [ ! -f "$HERMES_BIN" ] && [ ! -f "$HERMES_HOME/bin/hermes" ]; then
  echo "❌ 请先安装 Hermes: curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash"
  exit 1
fi
[ -f "$HERMES_BIN" ] || HERMES_BIN="$HERMES_HOME/bin/hermes"

# ── 0. 前置检查 ──
echo ""
echo "🔍 环境检查..."

# 0a. 用户同意
echo "  将创建 hermes-vip 用户（不可登录、不可 SSH）"
echo "  该用户用于执行你批准后的提权命令。"
read -p "是否继续安装 VIP？[Y/n] " consent
case "$consent" in
  [nN]|[nN][oO]) echo "❌ 已取消"; exit 1 ;;
  *) echo "  ✅ 已确认" ;;
esac

# 0b. 检查 root 用户
if ! getent passwd root > /dev/null 2>&1; then
  echo "❌ 系统中不存在 root 用户，VIP 需要 root 用户来运行 daemon"
  echo "  请先创建 root 用户后再安装"
  exit 1
fi
echo "  ✅ root 用户存在"

# 0c. 检查 Hermes 用户权限
echo "  🔍 $REAL_USER 的 sudo 权限:"

echo ""
echo "✅ 用户: $REAL_USER"
echo "✅ Hermes: $($HERMES_BIN --version 2>&1 | head -1)"

# ── 项目路径 ──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)"

# ── 1. 停旧 daemon ──
echo ""
echo "🛑 停止旧服务..."
if $IS_MAC; then
  sudo launchctl bootout system/com.hermes.vipd 2>/dev/null && echo "  已停止" || echo "  未运行"
else
  sudo systemctl stop hermes-vipd 2>/dev/null && echo "  已停止" || echo "  未运行"
fi

# ── 2. 装 Plugin（用真实用户身份）──
echo ""
echo "📦 安装 Plugin..."
sudo -u $REAL_USER mkdir -p "$HERMES_HOME/plugins/hermes-vip/"
if [ -d "$PROJECT_DIR/hermes-plugin" ]; then
  sudo -u $REAL_USER cp $PROJECT_DIR/hermes-plugin/*.py "$HERMES_HOME/plugins/hermes-vip/" 2>/dev/null
  sudo -u $REAL_USER cp $PROJECT_DIR/hermes-plugin/plugin.yaml "$HERMES_HOME/plugins/hermes-vip/" 2>/dev/null
fi
echo "  ✅ $HERMES_HOME/plugins/hermes-vip/"

# ── 3. 启用 Plugin ──
sudo -u $REAL_USER python3 -c "
import yaml, os
path = '$HERMES_HOME/config.yaml'
try:
  with open(path) as f: cfg = yaml.safe_load(f) or {}
except: cfg = {}
cfg.setdefault('plugins', {}).setdefault('enabled', [])
if 'hermes-vip' not in cfg['plugins']['enabled']:
  cfg['plugins']['enabled'].append('hermes-vip')
with open(path, 'w') as f: yaml.dump(cfg, f, default_flow_style=False)
print('  ✅ Plugin 已启用
')
"
echo ""

# ── 4. 备份旧配置 ──
if [ -f /etc/hermes-vip/config.yaml ]; then
  sudo cp /etc/hermes-vip/config.yaml "/etc/hermes-vip/config.yaml.bak.$(date +%Y%m%d)"
  echo "  ✅ 旧配置已备份到 config.yaml.bak.$(date +%Y%m%d)"
fi

# ── 5. 创建提权用户
if ! id hermes-vip >/dev/null 2>&1; then
  echo "  📋 创建提权用户 hermes-vip..."
  sudo useradd -r -s /sbin/nologin hermes-vip
  echo "    ✅ hermes-vip 已创建（不可登录、不可 SSH）"
fi

# ── 6. sudoers
if [ ! -f /etc/sudoers.d/hermes-vip ]; then
  sudo tee /etc/sudoers.d/hermes-vip > /dev/null << SUDOERS
hermes-vip ALL=(ALL) NOPASSWD: ALL
SUDOERS
  sudo chmod 440 /etc/sudoers.d/hermes-vip
  echo "  ✅ sudoers 已配置"
fi

# ── 7. 安装 Daemon（需要 root）──
if [ "$EUID" -ne 0 ]; then
  echo "🔧 需要 root 权限安装 daemon：sudo $0"
  exit 0
fi

if $IS_MAC; then
  VIP_RUN=/var/run/hermes-vip
else
  VIP_RUN=/run/hermes-vip
fi
VIP_BIN=/usr/local/bin/hermes-vipd
VIP_LIB=/usr/local/lib/hermes-vip
VIP_ETC=/etc/hermes-vip

sudo mkdir -p $VIP_LIB/daemon $VIP_LIB/connectors $VIP_ETC $VIP_RUN
sudo cp $PROJECT_DIR/daemon/*.py $VIP_LIB/daemon/
sudo cp $PROJECT_DIR/daemon/*.json $VIP_LIB/daemon/ 2>/dev/null || true
sudo cp $PROJECT_DIR/connectors/*.py $VIP_LIB/connectors/
echo '' | sudo tee $VIP_LIB/__init__.py > /dev/null

sudo tee $VIP_BIN > /dev/null << 'LAUNCHER'
#!/bin/bash
export PYTHONPATH="/usr/local/lib/hermes-vip:$PYTHONPATH"
exec python3 -m daemon.vipd "$@"
LAUNCHER
sudo chmod +x $VIP_BIN

# ── 6. 配置 ──
if [ ! -f $VIP_ETC/config.yaml ]; then
  sudo tee $VIP_ETC/config.yaml > /dev/null << CONF
trusted_user: $REAL_USER
sockets:
  request: $VIP_RUN/request.sock
  control: $VIP_RUN/control.sock
CONF
  sudo chmod 640 $VIP_ETC/config.yaml
  sudo chown hermes-vip:hermes-vip $VIP_ETC/config.yaml
fi

# ── 7. 注册服务 ──
if $IS_MAC; then
  sudo tee /Library/LaunchDaemons/com.hermes.vipd.plist > /dev/null << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.hermes.vipd</string>
<key>ProgramArguments</key><array><string>/usr/local/bin/hermes-vipd</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>UserName</key><string>root</string>
</dict></plist>
PLIST
  sudo launchctl load /Library/LaunchDaemons/com.hermes.vipd.plist 2>/dev/null || true
else
  sudo tee /etc/systemd/system/hermes-vipd.service > /dev/null << 'SERVICE'
[Unit]
Description=Hermes VIP Daemon
After=network.target
[Service]
Type=simple
User=hermes-vip
ExecStart=/usr/local/bin/hermes-vipd
Restart=always
RuntimeDirectory=hermes-vip
RuntimeDirectoryMode=0755
[Install]
WantedBy=multi-user.target
SERVICE
  sudo systemctl daemon-reload
  sudo systemctl enable hermes-vipd 2>/dev/null
  sudo chown hermes-vip:hermes-vip /etc/hermes-vip/config.yaml 2>/dev/null || true
sudo systemctl start hermes-vipd
fi

sleep 2
echo "  ✅ Daemon 已启动"

# 自动重启 Hermes（让插件生效）
echo ""
echo "🔄 重启 Hermes..."
pkill -f "hermes.desktop|hermes.chat|hermes_cli" 2>/dev/null || true
sleep 1
echo "  ✅ 已就绪"

echo ""
echo "┌─────────────────────────────────────────────┐"
echo "│  ✅ 安装完成                                 │"
echo "│                                             │"
echo "│  已启用沙箱隔离: /usr/local/bin/hermes-sandbox │"
echo "│  对话中可使用:                                │"
echo "│    /vip-pending   查看待审批                 │"
echo "│    /vip-approve   批准请求                   │"
echo "│    /vip-deny      拒绝请求                   │"
echo "└─────────────────────────────────────────────┘"
