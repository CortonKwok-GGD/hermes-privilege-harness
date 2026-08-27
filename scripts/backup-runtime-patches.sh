#!/bin/bash
# backup-runtime-patches.sh — 找出并备份 runtime (~/.hermes/hermes-agent) 里
# 所有与 workspace 不同的手打 patch（deploy rsync --delete 会抹掉这些）
# 用法: bash ~/hermes-workspace/apps/hermes-vip/scripts/backup-runtime-patches.sh

SRC="$HOME/hermes-workspace/hermes-agent"
DST="$HOME/.hermes/hermes-agent"
OUT="$HOME/hermes-workspace/apps/hermes-vip/patches/runtime-diff-$(date +%Y%m%d)"
mkdir -p "$OUT"

echo "===== 1. 同步范围全量差异清单 (runtime vs workspace) ====="
for d in acp_adapter agent cron gateway hermes_cli plugins providers tools tui_gateway; do
  [ -d "$SRC/$d" ] || continue
  diff -rq "$DST/$d" "$SRC/$d" 2>/dev/null | grep "differ" | grep -v "__pycache__"
done
for f in "$SRC"/*.py; do
  b=$(basename "$f")
  [ -f "$DST/$b" ] || continue
  cmp -s "$DST/$b" "$f" || echo "differ: $b"
done

echo ""
echo "===== 2. MOA 相关文件差异 + 备份 ====="
for f in hermes_cli/moa_config.py hermes_cli/moa_cmd.py agent/moa_loop.py agent/moa_trace.py; do
  if [ -f "$DST/$f" ] && ! cmp -s "$DST/$f" "$SRC/$f"; then
    cp "$DST/$f" "$OUT/$(echo $f | tr '/' '_').runtime"
    diff -u "$SRC/$f" "$DST/$f" > "$OUT/$(echo $f | tr '/' '_').patch" || true
    echo "⚠️ 有差异: $f → 已备份到 $OUT/"
    echo "--- 差异内容:"
    diff "$SRC/$f" "$DST/$f" | head -40
  else
    echo "✓ 无差异: $f"
  fi
done

echo ""
echo "===== 3. 备份目录内容 ====="
ls -la "$OUT"
echo ""
echo "备份完成: $OUT"
echo "（升级前先跑本脚本，升级后如需恢复: cp $OUT/*.runtime 到对应位置）"
