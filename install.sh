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

# ── 平台 (唯一分叉点: deploy/platform.sh) ──
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/deploy/platform.sh"
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
if [ ! -x "$HERMES_BIN" ]; then
    echo "❌ 未检测到 Hermes Agent"
    echo "   先安装 Hermes (https://hermes-agent.nousresearch.com/docs), 再运行本脚本"
    exit 1
fi
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
BLOCKLIST_FILE="/etc/hermes-vip/blocklist.yaml"
PLUGIN_DIR="$HERMES_HOME/plugins/hermes-vip"

# ── bin 部署 (统一走 platform.sh 翻译器) ──
deploy_bin() { platform_bin_deploy "$1" "$2"; }

echo ""
echo "💾 备份现有部署..."
BK_DIR="$REAL_HOME/hermes-vip-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK_DIR"
[ -d "$PLUGIN_DIR" ] && cp -a "$PLUGIN_DIR" "$BK_DIR/plugins-vip" 2>/dev/null && echo "  ✅ 插件 -> $BK_DIR/plugins-vip"
[ -d "$VIP_LIB" ] && cp -a "$VIP_LIB" "$BK_DIR/vip-lib" 2>/dev/null && echo "  ✅ daemon -> $BK_DIR/vip-lib"
[ -f "$VIPD_BIN" ] && cp -a "$VIPD_BIN" "$BK_DIR/hermes-vipd" 2>/dev/null
[ -f "$CTL_BIN" ] && cp -a "$CTL_BIN" "$BK_DIR/hermes-container-ctl" 2>/dev/null
[ -f "$RUN_BIN" ] && cp -a "$RUN_BIN" "$BK_DIR/hermes-run" 2>/dev/null
[ -f "$VIP_ETC/config.yaml" ] && cp -a "$VIP_ETC/config.yaml" "$BK_DIR/daemon-config.yaml" 2>/dev/null
echo "  💾 备份目录: $BK_DIR"

echo "🧹 清理旧部署..."
platform_svc_uninstall
pkill -f "hermes-vipd" 2>/dev/null || true
pkill -f "daemon.vipd" 2>/dev/null || true
sleep 1
rm -f "$VIP_RUN/request.sock" "$VIP_RUN/control.sock" 2>/dev/null || true
rm -rf /usr/local/etc/hermes-vip 2>/dev/null || true                       # 旧 blocklist 目录残留
rm -f "$HERMES_HOME/scripts/hermes-vipd-watchdog.sh" 2>/dev/null || true  # 旧 watchdog（launchd 已取代）

echo "📦 部署 daemon..."
mkdir -p "$VIP_LIB/daemon" "$VIP_ETC" "$VIP_RUN" "$VIP_LOG"
cp "$PROJECT_DIR/daemon/"*.py "$VIP_LIB/daemon/"
touch "$VIP_LIB/__init__.py"
chmod -R 755 "$VIP_LIB"

# hermes-run 执行审计: run.log 组写权限(664)。目录 775 组写以便 FIFO 滚动(mv)。
# 组: Linux=hermes-vip(daemon 用户组), macOS=daemon(launchd 既有)。运行用户在组内即可追加。
touch "$VIP_LOG/run.log"
# 属组: Linux=hermes-vip(daemon 组), macOS 部署时 launchd chown _hermesvip:daemon 覆盖;
# 组内用户(hermes-test/mac 经 hermes-vip/daemon 组)可追加 + FIFO mv。
chown hermes-vip:hermes-vip "$VIP_LOG/run.log" 2>/dev/null || chown daemon:daemon "$VIP_LOG/run.log" 2>/dev/null || true
chmod 664 "$VIP_LOG/run.log" 2>/dev/null || true
chmod 775 "$VIP_LOG" 2>/dev/null || true
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

# blocklist: 新路径优先，旧路径(/usr/local/etc/hermes-vip)迁移
cp "$PROJECT_DIR/examples/blocklist.yaml" "$BLOCKLIST_FILE"   # 总是用最新模板（旧文件已备份）
chmod 640 "$BLOCKLIST_FILE" 2>/dev/null || true

echo "📦 部署插件..."
mkdir -p "$PLUGIN_DIR/sandbox"
cp "$PROJECT_DIR/hermes-plugin/"*.py "$PROJECT_DIR/hermes-plugin/plugin.yaml" "$PROJECT_DIR/hermes-plugin/config.yaml" "$PLUGIN_DIR/" 2>/dev/null || true
cp "$PROJECT_DIR/hermes-plugin/sandbox/"*.py "$PLUGIN_DIR/sandbox/" 2>/dev/null || true
find "$PLUGIN_DIR" -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
chown -R "$REAL_USER" "$PLUGIN_DIR" 2>/dev/null || true
# 安装期间临时禁用沙箱（容器未建好时避免 Hermes terminal 全锁）；容器建好后再启用
sudo -u "$REAL_USER" python3 - "$PLUGIN_DIR/config.yaml" <<'PYEOF'
import sys, yaml
p = sys.argv[1]
c = {}
try:
    c = yaml.safe_load(open(p)) or {}
except Exception:
    pass
c.setdefault('sandbox', {})['enabled'] = False
yaml.safe_dump(c, open(p, 'w'), allow_unicode=True, sort_keys=False)
print('sandbox temporarily disabled during install')
PYEOF

echo "📦 部署容器控制层..."
deploy_bin "$PROJECT_DIR/container/ctl.sh" "$CTL_BIN"
deploy_bin "$PROJECT_DIR/container/hermes-run.sh" "$RUN_BIN"
deploy_bin "$PROJECT_DIR/container/Dockerfile.hermes-vm" "$VIP_LIB/Dockerfile.hermes-vm"
rm -f /usr/local/bin/Dockerfile.hermes-vm 2>/dev/null || true   # 旧布局残留清理

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
    # macOS: brew/colima 必须用真实用户上下文（brew 拒绝 root）
    if ! command -v brew &>/dev/null; then
        echo "  📦 安装 Homebrew（需要你按提示确认 Enter/密码）..."
        sudo -u "$REAL_USER" bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
            echo "  ❌ Homebrew 安装失败，请手动安装: https://brew.sh"; exit 1
        }
    fi
    if ! command -v docker &>/dev/null; then
        echo "  📦 brew install colima docker..."
        sudo -u "$REAL_USER" brew install colima docker
    fi
    if ! sudo -u "$REAL_USER" docker context ls 2>/dev/null | grep -q colima; then
        echo "  🚀 colima start (--network-address: 修 macOS LNP 拦容器访 LAN)..."
        # network-address=true -> vmnet 内核 NAT 替代 usernet slirp (usernet 无 LNP 授权会被 macOS Local Network Privacy 拦 LAN TCP)
        # 2026-08-11 实测: 仅 macOS 生效, Linux docker 分支不受影响; tinc 内网 10.0.0.x 不受破坏
        # 注意: flag 仅新建 VM 生效; 已有实例需改 ~/.colima/default/colima.yaml network.address: true + colima restart
        sudo -u "$REAL_USER" colima start --memory 2 --network-address
    fi
    sudo -u "$REAL_USER" docker context use colima || true
    # 注册 colima 登录自启（重启后 docker 自动可用, 对齐 Linux systemctl enable docker）
    if sudo -u "$REAL_USER" brew services start colima >/dev/null 2>&1
    then
        echo "  colima auto-start registered (brew services)"
    else
        echo "  ⚠️  colima 自启注册失败, 可手动执行: brew services start colima"
    fi
    echo "  ✅ docker (Colima)"
fi

echo "🏗️  预拉基础镜像（registry mirror 兜底）..."
if ! sudo -u "$REAL_USER" docker image inspect alpine:3.20 >/dev/null 2>&1; then
    for src in docker.1panel.live/library/alpine:3.20 docker.m.daocloud.io/library/alpine:3.20 alpine:3.20; do
        if sudo -u "$REAL_USER" docker pull "$src" >/dev/null 2>&1; then
            sudo -u "$REAL_USER" docker tag "$src" alpine:3.20 2>/dev/null || true
            echo "  ✅ 基础镜像就绪 ($src)"
            break
        fi
    done
else
    echo "  ⏭  基础镜像已存在"
fi

echo "🏗️  构建镜像 + 创建容器..."
sudo -u "$REAL_USER" "$CTL_BIN" build
sudo -u "$REAL_USER" "$CTL_BIN" create
sudo -u "$REAL_USER" "$CTL_BIN" create --no-net

echo "🚀 安装 daemon 服务..."
platform_ensure_svc_user
chown -R "$(platform_svc_user)" "$VIP_LIB"
cp "$PROJECT_DIR/examples/$(basename "$(platform_svc_unit)")" "$(platform_svc_unit)"
platform_svc_install

echo "📦 生成部署清单 (DEPLOYED.json)..."
# shellcheck disable=SC1091
source "$PROJECT_DIR/deploy/manifest.sh"
PROJECT_DIR="$PROJECT_DIR" VIP_LIB="$VIP_LIB" VIP_ETC="$VIP_ETC" \
    CTL_BIN="$CTL_BIN" RUN_BIN="$RUN_BIN" PLUGIN_DIR="$PLUGIN_DIR" \
    BLOCKLIST_FILE="$BLOCKLIST_FILE" \
    gen_deployed_json "$VIP_LIB/DEPLOYED.json"

echo "📦 部署更新入口 (hermes-vip-update)..."
cat > /usr/local/bin/hermes-vip-update <<WRAP
#!/bin/bash
# 统一增量更新入口: auto(init→check→apply)。repo 位置从 DEPLOYED.json 自动读取。
exec bash "$PROJECT_DIR/deploy/update.sh" auto
WRAP
chmod 755 /usr/local/bin/hermes-vip-update

echo "🧪 验证..."
docker version --format 'server {{.Server.Version}}' 2>/dev/null | sed 's/^/  /' || true
sleep 2
# 容器已就绪，启用沙箱
sudo -u "$REAL_USER" python3 - "$PLUGIN_DIR/config.yaml" <<'PYEOF'
import sys, yaml
p = sys.argv[1]
c = {}
try:
    c = yaml.safe_load(open(p)) or {}
except Exception:
    pass
c.setdefault('sandbox', {})['enabled'] = True
yaml.safe_dump(c, open(p, 'w'), allow_unicode=True, sort_keys=False)
print('sandbox enabled - container ready')
PYEOF
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
