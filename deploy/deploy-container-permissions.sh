#!/bin/bash
# deploy-container-permissions.sh — 容器权限增强部署 (一条命令)
#   1) 官方增量管道 update.sh auto (ctl/hermes-run/插件/Dockerfile, 需 root)
#   2) 重建镜像 (内置 adb/ocr/工具链) + 重建容器
#   3) 自检: adb / tesseract / --root 装包通道
# 用法: bash ~/hermes-workspace/apps/hermes-vip/deploy/deploy-container-permissions.sh
set -e
REPO="$HOME/hermes-workspace/apps/hermes-vip"

echo "[1/4] 官方增量部署 (ctl/hermes-run/插件/Dockerfile)"
sudo bash "$REPO/deploy/update.sh" init --repo "$REPO"
sudo bash "$REPO/deploy/update.sh" auto --repo "$REPO"

echo "[2/4] 重建镜像 (内置 adb/tesseract/工具链)"
hermes-container-ctl build --no-cache

echo "[3/4] 重建容器"
hermes-container-ctl rebuild

echo "[4/4] verify"
hermes-run id -u
hermes-run adb version 2>/dev/null | head -1 || echo "adb missing"
hermes-run tesseract --version 2>/dev/null | head -1 || echo "tesseract missing"
hermes-run --root 'apk add --no-cache tree >/dev/null 2>&1 && echo ROOT_OK' || echo "ROOT_FAIL"
echo "DONE. 重启 Hermes Desktop 使插件改动生效。"
