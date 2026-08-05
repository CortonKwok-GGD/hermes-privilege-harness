#!/bin/bash
# deploy-hermes.sh — 将 workspace 的 Hermes 部署到 runtime 目录
#
# 流程:
#   1. git pull 拉取最新
#   2. rsync 同步到 ~/.hermes/hermes-agent/（runtime）
#   3. 打 VIP patch（dd-patches.sh）
#
# 用法: bash deploy/deploy-hermes.sh
#       （从 ~/hermes-workspace/hermes-agent/ 或任意目录运行均可）

set -euo pipefail

SRC="${HERMES_SRC:-$HOME/hermes-workspace/hermes-agent}"
DST="${HERMES_DST:-$HOME/.hermes/hermes-agent}"
VIP="$HOME/hermes-workspace/apps/hermes-vip"

echo "━━━ Hermes Deploy ━━━"
echo "  source:      $SRC"
echo "  runtime:     $DST"

# 1. 确认 source 是 git 仓库
if [ ! -d "$SRC/.git" ]; then
    echo "❌ 错误: $SRC 不是 git 仓库"
    echo "   设置 HERMES_SRC 指向正确的 workspace"
    exit 1
fi

# 2. 拉取
echo ""
echo "→ git pull..."
cd "$SRC"
git pull

# 3. 同步到 runtime（只同步必要的运行时代码，不含 .git）
echo ""
echo "→ 同步 hermes_cli/ 到 runtime..."
rsync -a --delete \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    "$SRC/hermes_cli/" "$DST/hermes_cli/"

echo "→ 同步 plugins/ 到 runtime..."
rsync -a --delete \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    "$SRC/plugins/" "$DST/plugins/"
echo "→ 同步 tools/ 到 runtime..."
rsync -a --delete \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    "$SRC/tools/" "$DST/tools/"

# 4. 清 .pyc
find "$DST" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find "$DST" -name '*.pyc' -delete 2>/dev/null || true

# 5. 打 VIP patch
echo ""
echo "→ 打 VIP patch..."
HERMES_REPO="$DST" bash "$VIP/deploy/dd-patches.sh"

echo ""
echo "━━━ 完成 ━━━"
echo "请重启 Desktop 使变更生效"
