#!/bin/bash
# analyze-runtime-diffs.sh — 全量分析 runtime vs workspace 差异：
#   1. 每个差异文件: diff -u (workspace → runtime) 写报告到 workspace 共享文件
#   2. 备份每个 runtime 版本到 patches/runtime-diff-<日期>/
# 报告在 ~/hermes-workspace/tmp/runtime-diffs.txt（容器可直接读取）
# 用法: bash ~/hermes-workspace/apps/hermes-vip/scripts/analyze-runtime-diffs.sh

SRC="$HOME/hermes-workspace/hermes-agent"
DST="$HOME/.hermes/hermes-agent"
REPORT="$HOME/hermes-workspace/tmp/runtime-diffs.txt"
OUT="$HOME/hermes-workspace/apps/hermes-vip/patches/runtime-diff-$(date +%Y%m%d)"
mkdir -p "$OUT"
: > "$REPORT"

echo "分析中... 报告: $REPORT"

for d in acp_adapter agent cron gateway hermes_cli plugins providers tools tui_gateway; do
  [ -d "$SRC/$d" ] || continue
  while IFS= read -r line; do
    f="${line#Files }"; f="${f%% and *}"
    rel="${f#$DST/}"
    [ -f "$SRC/$rel" ] || continue
    echo "===== $rel =====" >> "$REPORT"
    echo "--- diff -u (workspace → runtime) ---" >> "$REPORT"
    diff -u "$SRC/$rel" "$DST/$rel" >> "$REPORT" 2>&1
    echo "" >> "$REPORT"
    cp "$DST/$rel" "$OUT/$(echo "$rel" | tr '/' '_').runtime"
    echo "  $rel"
  done < <(diff -rq "$DST/$d" "$SRC/$d" 2>/dev/null | grep "differ" | grep -v "__pycache__")
done

for f in "$SRC"/*.py; do
  b=$(basename "$f")
  [ -f "$DST/$b" ] || continue
  if ! cmp -s "$DST/$b" "$f"; then
    echo "===== $b =====" >> "$REPORT"
    echo "--- diff -u (workspace → runtime) ---" >> "$REPORT"
    diff -u "$f" "$DST/$b" >> "$REPORT" 2>&1
    echo "" >> "$REPORT"
    cp "$DST/$b" "$OUT/${b}.runtime"
    echo "  $b"
  fi
done

echo ""
echo "完成。备份: $OUT/"
ls -la "$OUT"
echo "报告: $REPORT ($(wc -l < "$REPORT") 行)"
