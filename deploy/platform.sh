#!/bin/bash
# ================================================================
# deploy/platform.sh — 平台翻译器 (唯一分叉点)
#
# 所有脚本 (install.sh / update.sh / manifest.sh / 未来工具) source 本文件,
# 通过函数获取平台差异, 不在业务脚本里写 uname/launchctl/systemctl/dd 判断。
# 原则: 业务逻辑一份, 平台差异只在这一个文件里出现。
#
# 用法: source deploy/platform.sh
# 提供变量: IS_MAC IS_LINUX PLATFORM
# 提供函数: platform_bin_deploy / platform_restart_vipd / platform_svc_unit
#           platform_svc_user / platform_svc_install / platform_svc_uninstall
# ================================================================

PLATFORM="$(uname)"
IS_MAC=0; IS_LINUX=0
[ "$PLATFORM" = "Darwin" ] && IS_MAC=1
[ "$PLATFORM" = "Linux" ] && IS_LINUX=1
if [ "$IS_MAC" = "0" ] && [ "$IS_LINUX" = "0" ]; then
    echo "❌ Unsupported platform: $PLATFORM (仅支持 macOS / Linux)" >&2
    return 1 2>/dev/null || exit 1
fi

# ── 写文件到系统路径 (macOS SIP 保护 /usr/local/bin → dd) ──
platform_bin_deploy() {
    local src="$1" dst="$2"
    if [ "$IS_MAC" = "1" ]; then
        rm -f "$dst"; dd if="$src" of="$dst" 2>/dev/null; chmod 755 "$dst"
    else
        cp "$src" "$dst"; chmod 755 "$dst"
    fi
}

# ── daemon 服务单元文件路径 ──
platform_svc_unit() {
    if [ "$IS_MAC" = "1" ]; then
        echo "/Library/LaunchDaemons/com.hermes.vipd.plist"
    else
        echo "/etc/systemd/system/hermes-vipd.service"
    fi
}

# ── daemon 运行用户:组 (文件属主) ──
platform_svc_user() {
    if [ "$IS_MAC" = "1" ]; then
        echo "_hermesvip:daemon"
    else
        echo "hermes-vip:hermes-vip"
    fi
}

# ── 重启 vipd daemon (best-effort) ──
platform_restart_vipd() {
    if [ "$IS_MAC" = "1" ]; then
        local unit
        unit="$(platform_svc_unit)"
        launchctl unload "$unit" 2>/dev/null || true
        launchctl load "$unit" 2>/dev/null || true
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl restart hermes-vipd 2>/dev/null || true
    else
        echo "  ⚠️  未找到 systemctl, 请手动重启 vipd daemon" >&2
    fi
}

# ── 安装/启用服务 (install.sh 用) ──
platform_svc_install() {
    local unit
    unit="$(platform_svc_unit)"
    if [ "$IS_MAC" = "1" ]; then
        launchctl load "$unit" 2>/dev/null || true
    else
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable --now hermes-vipd 2>/dev/null || true
    fi
}

# ── 卸载/禁用服务 (uninstall.sh 用) ──
platform_svc_uninstall() {
    if [ "$IS_MAC" = "1" ]; then
        launchctl bootout system/com.hermes.vipd 2>/dev/null || true
    else
        systemctl stop hermes-vipd 2>/dev/null || true
        systemctl disable hermes-vipd 2>/dev/null || true
    fi
}

# ── 创建 daemon 系统用户 (不存在时) ──
platform_ensure_svc_user() {
    if [ "$IS_MAC" = "1" ]; then
        if ! id _hermesvip &>/dev/null; then
            dscl . -create /Users/_hermesvip
            dscl . -create /Users/_hermesvip UniqueID 450
            dscl . -create /Users/_hermesvip PrimaryGroupID 80
            dscl . -create /Users/_hermesvip NFSHomeDirectory /var/empty
            dscl . -create /Users/_hermesvip UserShell /usr/bin/false
        fi
        echo '_hermesvip ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/hermes-vip
        chmod 440 /etc/sudoers.d/hermes-vip
    else
        if ! id hermes-vip &>/dev/null; then
            useradd -r -s /sbin/nologin hermes-vip
        fi
        echo 'hermes-vip ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/hermes-vip
        chmod 440 /etc/sudoers.d/hermes-vip
    fi
}
