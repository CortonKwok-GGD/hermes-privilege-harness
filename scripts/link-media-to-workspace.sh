#!/bin/bash
# link-media-to-workspace.sh — Hermes 媒体写盘路径 symlink 到 workspace 统一共享卷（路线1）
# 2026-08-27 定稿：不挂载、不重建容器。workspace 已 rw 挂载进容器（同路径），
# 字节落 workspace 即容器可见；guard 拦 vision_analyze 后的终端 PIL 回退读翻译后路径。
# 用法（宿主 Mac 执行，幂等可重跑）：bash ~/hermes-workspace/apps/hermes-vip/scripts/link-media-to-workspace.sh
set -u

# 拒绝在容器内运行：容器内 ~/.hermes/cache 是 hermes-vm-root 的陈旧拷贝，改了会误导
if [ -f /.dockerenv ] || grep -qE 'docker|containerd' /proc/1/cgroup 2>/dev/null; then
  echo "ERROR: 请在宿主 Mac 上执行（容器内 .hermes/cache 是陈旧拷贝，不是真写盘位置）" >&2
  exit 1
fi

MEDIA="$HOME/hermes-workspace/tmp/hermes-media"
mkdir -p "$MEDIA"/{images,documents,audio,videos,screenshots,flat-images,attachments}

link_dir() {  # $1=源目录  $2=目标目录
  local src="$1" dst="$2"
  if [ -L "$src" ]; then echo "skip (already symlink): $src"; return 0; fi
  if [ -d "$src" ]; then
    if [ -n "$(ls -A "$src" 2>/dev/null)" ]; then
      mv "$src"/* "$dst"/ 2>/dev/null && echo "moved contents: $src -> $dst"
    fi
    rmdir "$src" 2>/dev/null || { echo "ERROR: cannot remove $src (non-empty?)" >&2; return 1; }
  fi
  ln -s "$dst" "$src" && echo "linked: $src -> $dst"
}

for d in images documents audio videos screenshots; do
  link_dir "$HOME/.hermes/cache/$d" "$MEDIA/$d"
done
# 桌面/剪贴板上传平铺目录 ~/.hermes/images
link_dir "$HOME/.hermes/images" "$MEDIA/flat-images"
# 桌面二进制附件 staging（上游 PR #81717 服务端暂存目录）
link_dir "$HOME/.hermes/attachments" "$MEDIA/attachments"

echo
echo "--- 结果 ---"
ls -la "$HOME/.hermes/cache" "$HOME/.hermes" | grep '^l' || true
echo "共享卷: $MEDIA"
