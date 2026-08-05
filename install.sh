#!/bin/bash
# ================================================================
# Hermes VIP — 统一安装器 v9.1
# docker 语义两端一致: Linux 原生 docker / macOS Colima 提供 dockerd
# 共用主体 + 平台段（服务管理 / docker 提供 / bin 写入方式）
# 用法: sudo bash install.sh
# ================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

# ── 平台 ──
PLATFORM="$(uname)"
IS_MAC=0; IS_LINUX=0
[ "$PLATFORM" = "Darwin" ] && IS_MAC=1
[ "$PLATFORM" = "Linux" ] && IS_LINUX=1
if [ "$IS_MAC" = "0" ] && [ "$IS_LINUX" = "0" ]; then
    echo "❌ Unsupported platform: $PLATFORM"; exit 1
fi
[ "$EUID" -eq 0 ] || { echo "❌ 需要 root: sudo bash install.sh"; exit 1; }

# ── 真实用户 / Hermes home / 版本（共用）──
REAL_USER="${SUDO_USER:-}"
[ -z "$REAL_USER" ] && REAL_USER="$(logname 2>/dev/null || echo '')"
[ -z "$REAL_USER" ] && REAL_USER="$(who am i 2>/dev/null | awk '{print $1}' || echo '')"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    echo "❌ 无法检测当前用户。手动: REAL_USER=用户名 sudo -E bash install.sh"; exit 1
fi
REAL_HOME="$(eval echo ~$REAL_USER)"
HERMES_HOME="${HERMES_HOME:-$REAL_HOME/.hermes}"
echo "👤 $REAL_USER (home=$REAL_HOME)  platform=$PLATFORM"

MIN_HERMES="0.18.0"
hermes_version() { "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0"; }
version_gte() { printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 | grep -qx "$1"; }
HERMES_BIN="$(sudo -u "$REAL_USER" which hermes 2>/dev/null || echo "$HERMES_HOME/bin/hermes")"
HERMES_VER="$(hermes_version "$HERMES_BIN")"
if ! version_gte "$HERMES_VER" "$MIN_HERMES"; then
    echo "❌ Hermes $HERMES_VER < $MIN_HERMES（不支持原生审批卡片）"; exit 1
fi
echo "🆗 Hermes $HERMES_VER ($HERMES_BIN)"

# ── 路径 ──
VIP_LIB="/usr/local/lib/hermes-vip"
VIP_ETC="/etc/hermes-vip"
VIP_RUN="/var/run/hermes-vip"
VIP_LOG="/var/log/hermes-vip"
CTL_BIN="/usr/local/bin/hermes-container-ctl"
RUN_BIN="/usr/local/bin/hermes-run"
VIPD_BIN="/usr/local/bin/hermes-vipd"
BLOCKLIST_FILE="/usr/local/etc/hermes-vip/blocklist.yaml"
PLUGIN_DIR="$HERMES_HOME/plugins/hermes-vip"

# ── bin 部署（平台段: Mac SIP → dd）──
deploy_bin() {
    local src="$1" dst="$2"
    if [ "$IS_MAC" = "1" ]; then
        rm -f "$dst"; dd if="$src" of="$dst" 2>/dev/null; chmod 755 "$dst"
    else
        cp "$src" "$dst"; chmod 755 "$dst"
    fi
}

echo ""
echo "🧹 清理旧部署..."
if [ "$IS_LINUX" = "1" ]; then
    systemctl stop hermes-vipd 2>/dev/null || true
    systemctl disable hermes-vipd 2>/dev/null || true
else
    launchctl bootout system/com.hermes.vipd 2>/dev/null || true
fi
pkill -f "hermes-vipd" 2>/dev/null || true
pkill -f "daemon.vipd" 2>/dev/null || true
sleep 1
rm -f "$VIP_RUN/request.sock" "$VIP_RUN/control.sock" 2>/dev/null || true

echo "📦 部署 daemon..."
mkdir -p "$VIP_LIB/daemon" "$VIP_ETC" "$VIP_RUN" "$VIP_LOG" /usr/local/etc/hermes-vip
cp "$PROJECT_DIR/daemon/"*.py "$VIP_LIB/daemon/"
touch "$VIP_LIB/__init__.py"
chmod -R 755 "$VIP_LIB"
cat > "$VIPD_BIN" << 'WRAP'
#!/bin/bash
export PYTHONPATH="/usr/local/lib/hermes-vip:$PYTHONPATH"
cd /usr/local/lib/hermes-vip
HOME=/var/empty
exec python3 -m daemon.vipd "$@"
WRAP
chmod 755 "$VIPD_BIN"

# daemon config: trusted_user 必须顶层（vipd.py 读 config.get("trusted_user")）
if [ ! -f "$VIP_ETC/config.yaml" ]; then
    cp "$PROJECT_DIR/examples/config.yaml" "$VIP_ETC/config.yaml"
fi
python3 - "$VIP_ETC/config.yaml" "$REAL_USER" <<'PYEOF'
import sys, yaml
path, user = sys.argv[1], sys.argv[2]
c = {}
try:
    c = yaml.safe_load(open(path)) or {}
except Exception:
    pass
c['trusted_user'] = user
with open(path, 'w') as f:
    yaml.safe_dump(c, f, allow_unicode=True, sort_keys=False)
print('trusted_user ->', user)
PYEOF
chmod 644 "$VIP_ETC/config.yaml"

[ -f "$BLOCKLIST_FILE" ] || cp "$PROJECT_DIR/examples/blocklist.yaml" "$BLOCKLIST_FILE"
chmod 640 "$BLOCKLIST_FILE" 2>/dev/null || true

echo "📦 部署插件..."
mkdir -p "$PLUGIN_DIR/sandbox"
cp "$PROJECT_DIR/hermes-plugin/"*.py "$PROJECT_DIR/hermes-plugin/plugin.yaml" "$PROJECT_DIR/hermes-plugin/config.yaml" "$PLUGIN_DIR/" 2>/dev/null || true
cp "$PROJECT_DIR/hermes-plugin/sandbox/"*.py "$PLUGIN_DIR/sandbox/" 2>/dev/null || true
find "$PLUGIN_DIR" -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
chown -R "$REAL_USER" "$PLUGIN_DIR" 2>/dev/null || true

echo "📦 部署容器控制层..."
deploy_bin "$PROJECT_DIR/container/ctl.sh" "$CTL_BIN"
deploy_bin "$PROJECT_DIR/container/hermes-run.sh" "$RUN_BIN"
deploy_bin "$PROJECT_DIR/container/Dockerfile.hermes-vm" /usr/local/bin/Dockerfile.hermes-vm

echo "🔧 准备 docker..."
if [ "$IS_LINUX" = "1" ]; then
    if ! command -v docker &>/dev/null; then
        echo "  📦 apt install docker.io..."
        apt-get update -qq && apt-get install -y -qq docker.io
        systemctl enable --now docker
    fi
    usermod -aG docker "$REAL_USER"
    if ! grep -q registry-mirrors /etc/docker/daemon.json 2>/dev/null; then
        printf '{\n  "registry-mirrors": ["https://docker.1panel.live", "https://docker.m.daocloud.io"]\n}\n' > /etc/docker/daemon.json
        systemctl restart docker
    fi
    echo "  ✅ docker $(docker --version 2>/dev/null | grep -oE '[0-9.]+' | head -1)"
else
    if ! command -v docker &>/dev/null; then
        echo "  📦 brew install colima docker..."
        brew install colima docker
    fi
    if ! docker context ls 2>/dev/null | grep -q colima; then
        echo "  🚀 colima start..."
        colima start --memory 2
    fi
    docker context use colima || true
    echo "  ✅ docker (Colima)"
fi

echo "🏗️  构建镜像 + 创建容器..."
sudo -u "$REAL_USER" "$CTL_BIN" build
sudo -u "$REAL_USER" "$CTL_BIN" create
sudo -u "$REAL_USER" "$CTL_BIN" create --no-net

echo "🚀 安装 daemon 服务..."
if [ "$IS_LINUX" = "1" ]; then
    id hermes-vip &>/dev/null || useradd -r -s /sbin/nologin hermes-vip
    echo 'hermes-vip ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/hermes-vip
    chmod 440 /etc/sudoers.d/hermes-vip
    chown -R hermes-vip:hermes-vip "$VIP_LIB"
    cp "$PROJECT_DIR/examples/hermes-vipd.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now hermes-vipd
else
    if ! id _hermesvip &>/dev/null; then
        dscl . -create /Users/_hermesvip
        dscl . -create /Users/_hermesvip UniqueID 450
        dscl . -create /Users/_hermesvip PrimaryGroupID 80
        dscl . -create /Users/_hermesvip NFSHomeDirectory /var/empty
        dscl . -create /Users/_hermesvip UserShell /usr/bin/false
    fi
    echo '_hermesvip ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/hermes-vip
    chmod 440 /etc/sudoers.d/hermes-vip
    chown -R _hermesvip:daemon "$VIP_LIB"
    cp "$PROJECT_DIR/examples/com.hermes.vipd.plist" /Library/LaunchDaemons/
    launchctl load /Library/LaunchDaemons/com.hermes.vipd.plist
fi

echo "🧪 验证..."
sleep 2
sudo -u "$REAL_USER" "$CTL_BIN" status 2>&1 | head -5
python3 - "$VIP_RUN/request.sock" <<'PYEOF'
import json, struct, socket, sys
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(3)
    s.connect(sys.argv[1])
    req = json.dumps({'type': 'ping'}).encode()
    s.sendall(struct.pack('!I', len(req)) + req)
    data = s.recv(4)
    print('daemon:', 'active' if len(data) == 4 else 'unknown')
    s.close()
except Exception as e:
    print('daemon: not reachable (%s)' % e)
PYEOF

echo ""
echo "┌─────────────────────────────────────────────┐"
echo "│  ✅ Hermes VIP v9.1 安装完成                 │"
echo "│  容器: docker (${PLATFORM})                  │"
echo "│  重启 Hermes 生效（插件加载）                │"
echo "└─────────────────────────────────────────────┘"
