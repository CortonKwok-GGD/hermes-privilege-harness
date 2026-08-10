#!/bin/bash
# deploy-container-permissions.sh — 一条命令部署容器权限增强:
#   1) 部署新 ctl.sh / hermes-run.sh（支持 --root 容器内 root 通道）
#   2) 部署 guard.py / __init__.py（透传 + 提示语）
#   3) 重建镜像（内置 adb / tesseract-ocr / 编译工具链）
#   4) 重建容器 + 自检
# 用法: bash ~/hermes-workspace/apps/hermes-vip/deploy/deploy-container-permissions.sh
set -e
REPO="$HOME/hermes-workspace/apps/hermes-vip"
PLUGIN="$HOME/.hermes/plugins/hermes-vip"

echo "[1/5] deploy ctl + hermes-run"
sudo rm -f /usr/local/bin/hermes-container-ctl /usr/local/bin/hermes-run
sudo dd if="$REPO/container/ctl.sh" of=/usr/local/bin/hermes-container-ctl 2>/dev/null
sudo dd if="$REPO/container/hermes-run.sh" of=/usr/local/bin/hermes-run 2>/dev/null
sudo chmod 755 /usr/local/bin/hermes-container-ctl /usr/local/bin/hermes-run
sudo mkdir -p /usr/local/lib/hermes-vip
sudo dd if="$REPO/container/Dockerfile.hermes-vm" of=/usr/local/lib/hermes-vip/Dockerfile.hermes-vm 2>/dev/null

echo "[2/5] deploy plugin (guard passthrough + inject hint)"
cp "$REPO/hermes-plugin/guard.py" "$PLUGIN/guard.py"
cp "$REPO/hermes-plugin/__init__.py" "$PLUGIN/__init__.py"
rm -rf "$PLUGIN/__pycache__" "$PLUGIN"/sandbox/__pycache__ 2>/dev/null || true

echo "[3/5] build image (adb/ocr/toolchain baked in)"
hermes-container-ctl build

echo "[4/5] rebuild container"
hermes-container-ctl rebuild

echo "[5/5] verify"
hermes-run whoami
hermes-run adb version 2>/dev/null | head -1 || echo "adb missing"
hermes-run tesseract --version 2>/dev/null | head -1 || echo "tesseract missing"
hermes-run --root 'apk add --no-cache tree >/dev/null 2>&1 && echo ROOT_OK' || echo "ROOT_FAIL"
echo "DONE. 重启 Hermes Desktop 使插件改动生效。"
