#!/bin/bash
# ================================================================
# Hermes VIP — 卸载器
# 备份现有部署 → 交互确认每类删除 → 清除部署 → 恢复指引
# 用户数据（hermes-vm-root 等）不删除，只告知位置，由用户决定
# 用法: sudo bash uninstall.sh          （交互确认）
#       sudo bash uninstall.sh --yes    （自动确认全部删除，测试/自动化用）
# 备份位置: ~/hermes-vip-backup-uninstall-<时间戳>/
# ================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTO=0
[ "${1:-}" = "--yes" ] && AUTO=1

PLATFORM="$(uname)"
IS_MAC=0; IS_LINUX=0
[ "$PLATFORM" = "Darwin" ] && IS_MAC=1
[ "$PLATFORM" = "Linux" ] && IS_LINUX=1
[ "$EUID" -eq 0 ] || { echo "❌ 需要 root: sudo bash uninstall.sh"; exit 1; }

REAL_USER="${SUDO_USER:-}"
[ -z "$REAL_USER" ] && REAL_USER="$(logname 2>/dev/null || echo '')"
[ -z "$REAL_USER" ] && REAL_USER="$(who am i 2>/dev/null | awk '{print $1}' || echo '')"
[ -z "$REAL_USER" ] && REAL_USER="root"
REAL_HOME="$(eval echo ~$REAL_USER)"
HERMES_HOME="${HERMES_HOME:-$REAL_HOME/.hermes}"

VIP_LIB="/usr/local/lib/hermes-vip"
VIP_ETC="/etc/hermes-vip"
VIP_RUN="/var/run/hermes-vip"
CTL_BIN="/usr/local/bin/hermes-container-ctl"
RUN_BIN="/usr/local/bin/hermes-run"
VIPD_BIN="/usr/local/bin/hermes-vipd"
PLUGIN_DIR="$HERMES_HOME/plugins/hermes-vip"
SERVICE_FILE="/etc/systemd/system/hermes-vipd.service"
PLIST_FILE="/Library/LaunchDaemons/com.hermes.vipd.plist"
SUDOERS_FILE="/etc/sudoers.d/hermes-vip"

ask() {
    # ask "描述" → 默认 Y 返回 0，N 返回 1
    local desc="$1"
    [ "$AUTO" = "1" ] && { echo "  ⏭  $desc → 是 (--yes)"; return 0; }
    read -r -p "  删除 $desc? [Y/n] " ans
    case "${ans:-y}" in
        y|Y|yes|YES) return 0 ;;
        *) echo "  ⏭  保留 $desc"; return 1 ;;
    esac
}

echo "┌─────────────────────────────────────────────┐"
echo "│  Hermes VIP — 卸载                          │"
echo "│  备份 + 交互确认，可安全恢复                 │"
echo "└─────────────────────────────────────────────┘"
echo "👤 $REAL_USER (home=$REAL_HOME)  platform=$PLATFORM"

# ── 1. 检测部署 ──
FOUND=0
[ -d "$VIP_LIB" ] && FOUND=1
[ -d "$PLUGIN_DIR" ] && FOUND=1
[ -x "$CTL_BIN" ] && FOUND=1
[ "$IS_LINUX" = "1" ] && [ -f "$SERVICE_FILE" ] && FOUND=1
[ "$IS_MAC" = "1" ] && [ -f "$PLIST_FILE" ] && FOUND=1
if [ "$FOUND" = "0" ]; then
    echo "ℹ️  未检测到 Hermes VIP 部署，无需卸载。"
    exit 0
fi

# ── 2. 备份（自动，告知位置）──
BK_DIR="$REAL_HOME/hermes-vip-backup-uninstall-$(date +%Y%m%d-%H%M%S)"
echo ""
echo "💾 备份到: $BK_DIR"
mkdir -p "$BK_DIR"
[ -d "$PLUGIN_DIR" ] && cp -a "$PLUGIN_DIR" "$BK_DIR/plugins-vip" && echo "  ✅ 插件 -> $BK_DIR/plugins-vip"
[ -d "$VIP_LIB" ] && cp -a "$VIP_LIB" "$BK_DIR/vip-lib" && echo "  ✅ daemon -> $BK_DIR/vip-lib"
[ -f "$VIPD_BIN" ] && cp -a "$VIPD_BIN" "$BK_DIR/hermes-vipd" 2>/dev/null
[ -f "$CTL_BIN" ] && cp -a "$CTL_BIN" "$BK_DIR/hermes-container-ctl" 2>/dev/null
[ -f "$RUN_BIN" ] && cp -a "$RUN_BIN" "$BK_DIR/hermes-run" 2>/dev/null
[ -f "$VIP_ETC/config.yaml" ] && cp -a "$VIP_ETC/config.yaml" "$BK_DIR/daemon-config.yaml" 2>/dev/null
[ -f "$VIP_ETC/blocklist.yaml" ] && cp -a "$VIP_ETC/blocklist.yaml" "$BK_DIR/blocklist.yaml" 2>/dev/null
echo "  ✅ 备份完成。恢复方法见最后说明。"

# ── 3. 停服务 ──
echo ""
echo "🛑 停止 daemon 服务..."
if [ "$IS_LINUX" = "1" ]; then
    systemctl stop hermes-vipd 2>/dev/null || true
    systemctl disable hermes-vipd 2>/dev/null || true
else
    launchctl bootout system/com.hermes.vipd 2>/dev/null || true
fi
pkill -f "hermes-vipd" 2>/dev/null || true
sleep 1
echo "  ✅ 已停止"

# ── 4. 交互删除（每类确认）──
echo ""
echo "🗑️  以下内容将被删除（每类可单独确认）:"

if ask "daemon 程序与配置 (/usr/local/lib/hermes-vip, /etc/hermes-vip)"; then
    rm -rf "$VIP_LIB" "$VIP_ETC"
    rm -f "$VIPD_BIN"
    rm -f /usr/local/bin/Dockerfile.hermes-vm 2>/dev/null || true
    echo "  ✅ daemon 已删除"
fi

if ask "容器控制层 (hermes-container-ctl, hermes-run)"; then
    rm -f "$CTL_BIN" "$RUN_BIN"
    echo "  ✅ 容器控制层已删除"
fi

if ask "系统服务文件 (systemd/launchd)"; then
    [ "$IS_LINUX" = "1" ] && rm -f "$SERVICE_FILE" && systemctl daemon-reload 2>/dev/null || true
    [ "$IS_MAC" = "1" ] && rm -f "$PLIST_FILE"
    echo "  ✅ 服务文件已删除"
fi

if ask "sudoers 提权规则 (/etc/sudoers.d/hermes-vip)"; then
    rm -f "$SUDOERS_FILE"
    echo "  ✅ sudoers 已删除"
fi

if ask "Hermes 插件 (~/.hermes/plugins/hermes-vip)"; then
    rm -rf "$PLUGIN_DIR"
    echo "  ✅ 插件已删除（Hermes 重启后 VIP 工具消失）"
else
    echo "  ⏭  插件保留（VIP 工具仍可用，但 daemon 已停）"
fi

if ask "容器 hermes-vm / hermes-vm-no-net"; then
    if [ -x "$CTL_BIN" ]; then
        "$CTL_BIN" rm hermes-vm 2>/dev/null || true
        "$CTL_BIN" rm hermes-vm-no-net 2>/dev/null || true
    else
        docker rm -f hermes-vm hermes-vm-no-net 2>/dev/null || true
    fi
    echo "  ✅ 容器已删除"
fi

if ask "镜像 hermes-vm:latest"; then
    docker rmi hermes-vm:latest 2>/dev/null || true
    echo "  ✅ 镜像已删除"
fi

# ── 用户数据：不删除，仅告知位置（让用户自己决定删留）──
echo ""
echo "📦 你的数据（本卸载器不删除，保留原样）:"
echo "  - 容器数据目录: $REAL_HOME/hermes-vm-root"
echo "    （容器系统层持久化挂载源，含容器内配置文件/数据/装包）"
echo "    如需删除，手动执行: rm -rf $REAL_HOME/hermes-vm-root"
echo "  - 本次备份目录: $BK_DIR"
echo "    如需删除，手动执行: rm -rf $BK_DIR"
echo "  - 历史部署备份: $REAL_HOME/hermes-vip-backup-*（install.sh 每次部署前产生）"
echo "    如需删除，手动执行: rm -rf $REAL_HOME/hermes-vip-backup-*" 

# ── 5. 恢复指引 ──
echo ""
echo "┌─────────────────────────────────────────────┐"
echo "│  ✅ Hermes VIP 已卸载                        │"
echo "│  备份: $BK_DIR        │"
echo "└─────────────────────────────────────────────┘"
echo ""
echo "恢复方法（两种）："
echo "  1) 完整恢复: sudo bash install.sh    （从 repo 重新安装）"
echo "  2) 从备份恢复: 备份在 $BK_DIR"
echo "     复制回对应位置即可（插件→$PLUGIN_DIR, daemon→$VIP_LIB, 配置→$VIP_ETC），"
echo "     然后重装服务（install.sh）并重启 Hermes"
echo ""
echo "卸载后：Hermes 恢复正常执行（terminal 不再进容器），vip_sudo 不可用。"
