#!/bin/bash
# dd-config.sh — VIP 运行时 config 补丁（幂等，保注释）
# 2026-08-27: 桌面端图片/文件附件读不了 = 前端按"本地 gateway"发裸路径，
# 容器看不到。设 terminal.backend=docker 让网关 session-info 上报容器后端，
# 前端才走 image.attach_bytes/file.attach 字节上传 → staging 到容器可见目录。
# 仅影响网关上报；agent 终端后端仍由 TERMINAL_ENV 环境变量决定，不受影响。
set -u

TARGETS=("$HOME/.hermes/config.yaml")
for cfg in "$HOME"/.hermes/profiles/*/config.yaml; do
    [ -f "$cfg" ] && TARGETS+=("$cfg")
done

patched=0
for path in "${TARGETS[@]}"; do
    [ -f "$path" ] || { echo "  ⏭️  跳过(不存在): $path"; continue; }
    result=$(python3 - "$path" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

# 已有 backend 键 → 幂等跳过
for ln in lines:
    if ln.lstrip().startswith('backend:'):
        # 仅当它属于 terminal 段（上一非空行是 terminal:）
        prev = None
        for pl in lines[:lines.index(ln)]:
            if pl.strip():
                prev = pl
        if prev and prev.strip() == 'terminal:':
            print('skip')
            sys.exit(0)

# 找独立 terminal: 行
for i, ln in enumerate(lines):
    if ln.rstrip() == 'terminal:':
        lines.insert(i + 1, '  backend: docker\n')
        with open(path, 'w') as f:
            f.writelines(lines)
        print('patched')
        sys.exit(0)

# 无 terminal 段 → 追加
lines.append('terminal:\n')
lines.append('  backend: docker\n')
with open(path, 'w') as f:
    f.writelines(lines)
print('appended')
PYEOF
)
    case "$result" in
        patched)  echo "  ✅ $path 已加 terminal.backend: docker"; patched=1 ;;
        appended) echo "  ✅ $path 追加 terminal.backend: docker"; patched=1 ;;
        skip)     echo "  ⏭️  $path 已有 backend 键，跳过" ;;
        *)        echo "  ⚠️  $path 未处理: $result" ;;
    esac
done

echo ""
if [ "$patched" = "1" ]; then
    echo "✅ config 补丁完成 — 重启 Hermes Desktop 生效"
    echo "   然后重新发送图片，验证 staging: ls ~/hermes-workspace/tmp/hermes-media/attachments/"
else
    echo "✅ config 已是目标状态（无需改动）"
fi
