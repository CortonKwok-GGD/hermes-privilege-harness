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

# 3. 同步到 runtime。
# 历史教训 (2026-08-06): 只同步 hermes_cli/ + plugins/ + tools/ 会在跨文件
# 依赖变化时断裂（如 hermes_cli/update_cmd.py 依赖顶层 hermes_constants.py 的
# venv_python_path、agent/transports/codex.py 的符号）。runtime 需要完整的
# python 运行时镜像：顶层 *.py + 全部 python 包目录，排除非运行时代码。
echo ""
echo "→ 同步 python 运行时到 runtime..."

# 顶层 .py 模块（hermes_constants, model_tools, utils, toolsets 等）。
# 不用 --delete：顶层还有 venv/、apps/、website/ 等运行时/非运行时目录，
# delete 会因目录非空报错且可能误伤。只做增量同步。
mkdir -p "$DST"
rsync -a \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --include='*.py' \
    --include='*/' \
    --exclude='*' \
    "$SRC/" "$DST/"

# python 包目录（含 __init__.py 的可 import 目录）
for d in acp_adapter agent cron gateway hermes_cli plugins providers tools tui_gateway; do
    if [ -d "$SRC/$d" ]; then
        echo "  → $d/"
        rsync -a --delete \
            --exclude='__pycache__' \
            --exclude='*.pyc' \
            "$SRC/$d/" "$DST/$d/"
    fi
done

# 非 python 但运行必需的顶层文件
for f in cli-config.yaml.example setup.py toolset_distributions.py; do
    [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DST/$f"
done

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
