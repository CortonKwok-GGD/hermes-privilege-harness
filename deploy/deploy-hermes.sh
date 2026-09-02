#!/bin/bash
# deploy-hermes.sh — 一键部署 = git pull + 同步源码 + 打全部补丁
#
# 拆开版本（推荐一步步来）:
#   bash deploy/deploy-sync.sh                 # 1. 纯同步源码（不打补丁）
#   bash deploy/dd-patches.sh profiles.py      # 2. 逐个补丁
#   bash deploy/dd-patches.sh moa_config.py
#   ...（config_defaults.py inventory.py model_switch.py）
#   bash deploy/dd-patches.sh all              # 或一次全打
#
# 用法: bash deploy/deploy-hermes.sh
# 可选: HERMES_SRC / HERMES_DST 覆盖默认路径

set -euo pipefail

SRC="${HERMES_SRC:-$HOME/hermes-workspace/hermes-agent}"
DST="${HERMES_DST:-$HOME/.hermes/hermes-agent}"
VIP="$HOME/hermes-workspace/apps/hermes-vip"

echo "━━━ Hermes Deploy（一键）━━━"
echo "  source:  $SRC"
echo "  runtime: $DST"

if [ ! -d "$SRC/.git" ]; then
    echo "❌ 错误: $SRC 不是 git 仓库"
    echo "   设置 HERMES_SRC 指向正确的 workspace"
    exit 1
fi

echo ""
echo "→ git pull..."
cd "$SRC"
git pull

# 纯同步（rsync + 清 pyc，不打补丁）
HERMES_SRC="$SRC" HERMES_DST="$DST" bash "$VIP/deploy/deploy-sync.sh"

# 打全部补丁
echo ""
echo "→ 打 VIP patch（全部）..."
HERMES_REPO="$DST" bash "$VIP/deploy/dd-patches.sh" all

# deploy-sync 只同步文件、不动 runtime 的 git refs → 版本检测(读 git HEAD +
# .update_check 缓存)会报假的 10k+ behind。把 ref 指到官方最新并清缓存
# (2026-09-02 实测: hermes --version 在 deploy 后报 10145 commits behind)。
if [ -d "$DST/.git" ]; then
    git -C "$DST" fetch origin main -q 2>/dev/null || true
    git -C "$DST" update-ref refs/heads/main refs/remotes/origin/main 2>/dev/null || true
fi
rm -f "$(dirname "$DST")/.update_check" 2>/dev/null || true

echo ""
echo "━━━ 完成 ━━━"
echo "请重启 Desktop 使变更生效"
