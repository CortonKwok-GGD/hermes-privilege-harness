#!/bin/bash
# dd-patches.sh — 部署 VIP 补丁到 Hermes 核心代码
# 在 git pull 后自动运行（通过 post-merge hook）或手动执行

set -euo pipefail

HERMES_REPO="${HERMES_REPO:-$HOME/hermes-workspace/hermes-agent}"
P="$HERMES_REPO/hermes_cli/profiles.py"

if [ ! -f "$P" ]; then
    echo "❌ 找不到 profiles.py at $P"
    echo "   设置 HERMES_REPO 或确认路径"
    exit 1
fi

# ============================================================
# 1. 注入函数定义
# ============================================================
if grep -q "def _sync_profile_plugins" "$P" 2>/dev/null; then
    echo "  ✓ _sync_profile_plugins 已存在"
else
    echo "  → 注入 _sync_profile_plugins 到 profiles.py ..."
    python3 -c "
with open('$P') as f:
    content = f.read()
func = '''def _sync_profile_plugins(profile_dir, source_dir=None):
    \"\"\"Symlink all global plugins into profile_dir/plugins/.\"\"\"
    from hermes_cli.profiles import _get_default_hermes_home as _root
    target = profile_dir / \"plugins\"
    target.mkdir(parents=True, exist_ok=True)
    global_plugins = _root() / \"plugins\"
    if not global_plugins.is_dir():
        return
    for entry in global_plugins.iterdir():
        if not entry.is_dir():
            continue
        link = target / entry.name
        if link.exists():
            continue
        try:
            link.symlink_to(entry, target_is_directory=True)
        except OSError:
            pass

'''
marker = '\ndef seed_profile_skills('
if marker in content:
    content = content.replace(marker, '\n' + func + marker, 1)
    with open('$P', 'w') as f:
        f.write(content)
    print('  ✅ 函数注入完成')
else:
    print('  ❌ 找不到 seed_profile_skills 锚点')
    exit(1)
"
fi

# ============================================================
# 2. 注入调用点
# ============================================================
if grep -q "_sync_profile_plugins(profile_dir, source_dir)" "$P" 2>/dev/null; then
    echo "  ✓ 调用点已存在"
else
    echo "  → 注入调用点到 create_profile() ..."
    python3 -c "
with open('$P') as f:
    content = f.read()
anchor = '# Seed an empty .env'
insert = '\n    # VIP: symlink global plugins into new profile\n    _sync_profile_plugins(profile_dir, source_dir)\n'
if anchor in content:
    content = content.replace(anchor, insert + anchor, 1)
    with open('$P', 'w') as f:
        f.write(content)
    print('  ✅ 调用点注入完成')
else:
    print('  ❌ 找不到 anchor')
    exit(1)
"
fi

# ============================================================
# 3. 清理 .pyc 缓存
# ============================================================
rm -f "$HERMES_REPO/hermes_cli/__pycache__/profiles"*.pyc 2>/dev/null
echo "  ✓ .pyc 缓存已清理"

echo ""
echo "✅ VIP patches deployed"
echo "   - _sync_profile_plugins() injected (unified symlink from global)"
echo "   - Call site in create_profile()"
echo "   - .pyc cache cleared"
