#!/bin/bash
# diagnose-desktop-attach.sh — 诊断桌面附件为何不走 staging（raw path 直传）
# 输出写到 ~/hermes-workspace/tmp/attach-diagnose.txt（容器可读），Mac 上执行
OUT="$HOME/hermes-workspace/tmp/attach-diagnose.txt"
: > "$OUT"
{ 
echo "===== 1. 运行的 Hermes Desktop 进程 ====="
ps -ax -o pid,lstart,command 2>/dev/null | grep -i "Hermes.app" | grep -v grep

echo
echo "===== 2. 网关/后端进程（tui_gateway / hermes / uvicorn） ====="
ps -ax -o pid,lstart,command 2>/dev/null | grep -iE "tui_gateway|hermes-agent|uvicorn|hermes run|hermes gateway" | grep -v grep

echo
echo "===== 3. 运行中后端进程加载的代码路径（采样前 3 个进程） ====="
for pid in $(pgrep -f "tui_gateway|hermes" 2>/dev/null | head -3); do
  echo "--- PID $pid ---"
  lsof -p "$pid" 2>/dev/null | grep -E "hermes-agent|hermes-workspace" | awk '{print $NF}' | sort -u | head -5
done

echo
echo "===== 4. /Applications 里的 Hermes.app 构建时间 ====="
ls -la /Applications/ 2>/dev/null | grep -i hermes
ls -la "/Applications/Hermes.app/Contents/MacOS/" 2>/dev/null | head -3

echo
echo "===== 5. workspace release 构建时间（对比用） ====="
ls -la "$HOME/hermes-workspace/hermes-agent/apps/desktop/release/mac-arm64/Hermes.app/Contents/MacOS/" 2>/dev/null | head -3

echo
echo "===== 6. staging 目录现状 ====="
echo "--- ~/.hermes/attachments (symlink?):"
ls -la ~/.hermes/attachments 2>&1 | head -3
echo "--- ~/.hermes/images (symlink?):"
ls -la ~/.hermes/images 2>&1 | head -3
echo "--- ~/.hermes/cache/images:"
ls -la ~/.hermes/cache/images 2>&1 | head -3
echo "--- 最近 2 小时新增的媒体文件:"
find "$HOME/hermes-workspace/tmp/hermes-media" -type f -mmin -120 2>/dev/null | head -5
echo "--- ~/.hermes/ 根目录最近 2 小时新增:"
find "$HOME/.hermes" -maxdepth 2 -type f -mmin -120 2>/dev/null | grep -v hermes-agent | head -10

echo
echo "===== 7. Hermes.app 版本号 ====="
defaults read "/Applications/Hermes.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "(无 /Applications/Hermes.app 或读不到)"
} >> "$OUT" 2>&1
echo "诊断完成: $OUT"
