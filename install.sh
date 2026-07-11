#!/bin/bash
# Hermes VIP — 入口安装脚本
# 用法：bash install.sh
set -euo pipefail

cd "$(dirname "$0")"
echo "┌─────────────────────────────────────────────┐"
echo "│  Hermes VIP                                 │"
echo "└─────────────────────────────────────────────┘"
echo ""

if [ ! -f "examples/install-linux.sh" ] && [ ! -f "examples/install-macos.sh" ]; then
  echo "❌ 找不到安装脚本，请确保在 hermes-vip 目录下运行"
  exit 1
fi

case "$(uname)" in
  Darwin)
    bash examples/install-macos.sh
    ;;
  Linux)
    bash examples/install-linux.sh
    ;;
  *)
    echo "❌ 不支持的系统: $(uname)"
    exit 1
    ;;
esac
