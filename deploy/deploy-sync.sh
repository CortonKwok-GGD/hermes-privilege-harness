#!/bin/bash
# deploy-sync.sh — 只同步源码 workspace → runtime，不打任何补丁。
# 与 deploy-hermes.sh 拆开：先纯升级源码，再逐个跑 dd-patches.sh <文件>。
#
# 用法: bash deploy/deploy-sync.sh
# 可选: HERMES_SRC / HERMES_DST 覆盖默认路径

set -euo pipefail

SRC="${HERMES_SRC:-$HOME/hermes-workspace/hermes-agent}"
DST="${HERMES_DST:-$HOME/.hermes/hermes-agent}"

echo "━━━ Hermes Sync (仅源码) ━━━"
echo "  source:  $SRC"
echo "  runtime: $DST"

if [ ! -d "$SRC/.git" ]; then
    echo "❌ 错误: $SRC 不是 git 仓库"
    echo "   设置 HERMES_SRC 指向正确的 workspace"
    exit 1
fi

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

# 清 .pyc
find "$DST" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find "$DST" -name '*.pyc' -delete 2>/dev/null || true

echo ""
echo "━━━ 同步完成（未打补丁）━━━"
echo "下一步: bash deploy/dd-patches.sh profiles.py   # 逐个补丁，或 all 一次全打"
