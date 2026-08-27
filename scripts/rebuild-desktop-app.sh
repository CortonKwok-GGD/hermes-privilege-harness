#!/bin/bash
# rebuild-desktop-app.sh — 用当前源码重建 Hermes Desktop App 并部署到 runtime
# 2026-08-27: 桌面附件字节上传（image.attach_bytes/file.attach）是前端逻辑，
# 旧 App bundle（7/20）没有 → 附件只传裸路径。重建前端后服务端 staging 才触发。
# 用法（宿主 Mac 执行）: bash ~/hermes-workspace/apps/hermes-vip/scripts/rebuild-desktop-app.sh
set -euo pipefail

WS="$HOME/hermes-workspace/hermes-agent"
RUNTIME="$HOME/.hermes/hermes-agent"
REGISTRY="https://registry.npmjs.org"
APP_ABS="$WS/apps/desktop/release/mac-arm64/Hermes.app/Contents/Resources/app.asar"

# 0. 前置检查
command -v node >/dev/null || { echo "❌ node 不存在（Hermes 需要 Node 构建桌面端）"; exit 1; }
command -v npm  >/dev/null || { echo "❌ npm 不存在"; exit 1; }
echo "━━━ Hermes Desktop 重建 ━━━"
echo "  node: $(node -v)  npm: $(npm -v)  registry: $(npm config get registry)"

# 1. 关闭正在运行的 Hermes Desktop（用 runtime 拷贝）
echo "━━━ 关闭正在运行的 Hermes Desktop ━━━"
osascript -e 'quit app "Hermes"' 2>/dev/null && sleep 2 || echo "  ⚠️ 未能自动关闭 Hermes.app（可手动关）"

# 2. 新前端验证函数。注意：主 bundle 被 unpack 到 app.asar.unpacked/dist/assets/，
#    新版 @electron/asar 带 integrity 块 + unpacked，grep app.asar 本体读不到 JS 内容
app_fresh() {
    [ -f "$APP_ABS" ] || return 1
    if ls "$APP_ABS.unpacked/dist/assets/index-"*.js >/dev/null 2>&1; then
        grep -a -q "image.attach_bytes" "$APP_ABS.unpacked/dist/assets/"*.js 2>/dev/null && return 0
    fi
    grep -a -q "image.attach_bytes" "$APP_ABS" 2>/dev/null && return 0
    return 1
}

if app_fresh; then
    echo "━━━ 现有构建已含新前端（attach_bytes），跳过 npm ci + pack ━━━"
else
    # 3. 对齐依赖（官方 registry；npm ci 会重建 node_modules）
    cd "$WS"
    echo "━━━ npm ci（workspace deps，官方 registry）━━━"
    npm ci --workspace apps/desktop --registry "$REGISTRY" 2>&1 | tail -4 || {
        echo "❌ npm ci 失败（检查网络/registry: npm config get registry）"
        exit 1
    }

    # 4. 构建 + 打包（electron-builder --dir → release/mac-arm64/Hermes.app）
    cd apps/desktop
    echo "━━━ npm run pack（vite + electron-builder --dir）━━━"
    if ! npm run pack 2>&1 | tail -12; then
        echo "⚠️ 重试 pack（ELECTRON_MIRROR npmmirror 二进制镜像）..."
        ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron/" npm run pack 2>&1 | tail -12
    fi

    # 5. 验证新前端带 字节上传 RPC（PR #81717 链路）
    if app_fresh; then
        echo "✅ 构建产物含 image.attach_bytes（新前端）"
    else
        echo "❌ 构建产物不含 image.attach_bytes — 前端仍是旧逻辑，检查构建"
        exit 1
    fi
    ls -la "$APP_ABS"
fi

# 6. 部署到 runtime（App 实际运行位置，diagnose 已确认）
echo "━━━ 部署到 runtime ━━━"
mkdir -p "$RUNTIME/apps/desktop/release"
rsync -a --delete "$WS/apps/desktop/release/" "$RUNTIME/apps/desktop/release/"
echo "✅ 已同步到 runtime: $RUNTIME/apps/desktop/release/mac-arm64/Hermes.app"

echo ""
echo "━━━ 完成 ━━━"
echo "启动: open $RUNTIME/apps/desktop/release/mac-arm64/Hermes.app"
echo "验证: 发一张图，检查 ~/hermes-workspace/tmp/hermes-media/flat-images/ 或 attachments/ 是否出现新文件"
