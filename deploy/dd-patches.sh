#!/bin/bash
# dd-patches.sh — 打 VIP 补丁到 Hermes 核心代码（锚点注入、幂等）
#
# 用法（默认目标 = runtime ~/.hermes/hermes-agent，与 deploy 语义一致）:
#   bash dd-patches.sh              # 打全部补丁
#   bash dd-patches.sh all          # 同上
#   bash dd-patches.sh profiles.py  # 只打某一个（按文件名）
# 覆盖目标: HERMES_REPO=/path bash dd-patches.sh ...
#   bash dd-patches.sh moa_config.py
#   bash dd-patches.sh config_defaults.py
#   bash dd-patches.sh inventory.py
#   bash dd-patches.sh model_switch.py
#   bash dd-patches.sh credential_files.py
#
# 补丁清单:
#   profiles.py        — _sync_profile_plugins 全局插件跨 profile 可见
#   moa_config.py      — 清空默认 MoA 参考模型 + aggregator（未订阅 provider）
#   config_defaults.py — 内置 default preset 清空 + disabled
#   inventory.py       — picker 只显示 enabled preset
#   model_switch.py    — fallback 空串（不落回未订阅 default preset）
#   credential_files.py — 媒体路径翻译到 workspace 共享卷（hermes-run 容器读图）
#
# 说明: MOA 四个文件的补丁已随 git main 提交（c03f329e46 / 4d186af3f9），
# 同步后即已在源码里，此处为幂等校验（命中即跳过）。profiles.py 的注入
# 只在 runtime 存在（不入 git），每次部署必须重打。

set -euo pipefail

HERMES_REPO="${HERMES_REPO:-$HOME/.hermes/hermes-agent}"   # 默认打 runtime；部署语义一致
REQUESTED="${1:-all}"

if [ ! -f "$HERMES_REPO/hermes_cli/profiles.py" ]; then
    echo "❌ 找不到 $HERMES_REPO/hermes_cli/profiles.py"
    echo "   设置 HERMES_REPO 或确认路径"
    exit 1
fi

# ============================================================
# profiles.py — 注入函数定义 + 调用点（两处，一个逻辑补丁）
# ============================================================
patch_profiles() {
    local P="$HERMES_REPO/hermes_cli/profiles.py"
    if grep -q "def _sync_profile_plugins" "$P" 2>/dev/null; then
        echo "  ✓ profiles.py 函数已存在"
    else
        echo "  → 注入 _sync_profile_plugins ..."
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
    if grep -q "_sync_profile_plugins(profile_dir, source_dir)" "$P" 2>/dev/null; then
        echo "  ✓ profiles.py 调用点已存在"
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
}

# ============================================================
# moa_config.py — 清空默认参考模型 + aggregator
# ============================================================
patch_moa_config() {
    local MC="$HERMES_REPO/hermes_cli/moa_config.py"
    if grep -q "VIP patch 2026-08-05" "$MC" 2>/dev/null; then
        echo "  ✓ moa_config.py 已打补丁（git main 自带，同步后即生效）"
    else
        echo "  → 补丁 moa_config.py ..."
        python3 - "$MC" << 'PYEOF'
import sys
p = sys.argv[1]
with open(p) as f:
    c = f.read()

old_refs = '''DEFAULT_MOA_REFERENCE_MODELS: list[dict[str, str]] = [
    {"provider": "openai-codex", "model": "gpt-5.5"},
    {"provider": "openrouter", "model": "deepseek/deepseek-v4-pro"},
]'''
new_refs = '''# VIP patch 2026-08-05: default MoA preset referenced unsubscribed providers
# (openai-codex / openrouter) and slowed startup. Kept empty; user presets
# come from config.yaml only.
DEFAULT_MOA_REFERENCE_MODELS: list[dict[str, str]] = []'''

old_agg = '''DEFAULT_MOA_AGGREGATOR: dict[str, str] = {
    "provider": "openrouter",
    "model": "anthropic/claude-opus-4.8",
}'''
new_agg = '''DEFAULT_MOA_AGGREGATOR: dict[str, str] = {
    "provider": "",
    "model": "",
}'''

ok = True
if old_refs in c:
    c = c.replace(old_refs, new_refs, 1)
else:
    print("  ❌ moa_config.py 找不到 reference_models 锚点"); ok = False
if old_agg in c:
    c = c.replace(old_agg, new_agg, 1)
else:
    print("  ❌ moa_config.py 找不到 aggregator 锚点"); ok = False
if ok:
    with open(p, 'w') as f:
        f.write(c)
    print("  ✅ moa_config.py 补丁完成")
else:
    sys.exit(1)
PYEOF
    fi
}

# ============================================================
# config_defaults.py — 内置 default preset 清空 + disabled
# ============================================================
patch_config_defaults() {
    local CD="$HERMES_REPO/hermes_cli/config_defaults.py"
    if grep -q "VIP patch 2026-08-05: built-in default preset" "$CD" 2>/dev/null; then
        echo "  ✓ config_defaults.py 已打补丁（git main 自带）"
    else
        echo "  → 补丁 config_defaults.py ..."
        python3 - "$CD" << 'PYEOF'
import sys
p = sys.argv[1]
with open(p) as f:
    c = f.read()
old = '''            "default": {
                "reference_models": [
                    {"provider": "openai-codex", "model": "gpt-5.5"},
                    {"provider": "openrouter", "model": "deepseek/deepseek-v4-pro"},
                ],
                "aggregator": {"provider": "openrouter", "model": "anthropic/claude-opus-4.8"},
                "max_tokens": 4096,
                "enabled": True,
            }'''
new = '''            # VIP patch 2026-08-05: built-in default preset references
            # unsubscribed providers (openai-codex / openrouter) and slows
            # startup. User presets live in config.yaml — keep this empty.
            "default": {
                "reference_models": [],
                "aggregator": {"provider": "", "model": ""},
                "max_tokens": 4096,
                "enabled": False,
            }'''
if old in c:
    c = c.replace(old, new, 1)
    with open(p, 'w') as f:
        f.write(c)
    print("  ✅ config_defaults.py 补丁完成")
else:
    print("  ❌ config_defaults.py 找不到 default preset 锚点")
    sys.exit(1)
PYEOF
    fi
}

# ============================================================
# inventory.py — picker 只显示 enabled preset
# ============================================================
patch_inventory() {
    local INV="$HERMES_REPO/hermes_cli/inventory.py"
    if grep -q "Only surface \*enabled\* presets" "$INV" 2>/dev/null; then
        echo "  ✓ inventory.py 已打补丁（git main 自带）"
    else
        echo "  → 补丁 inventory.py ..."
        python3 - "$INV" << 'PYEOF'
import sys
p = sys.argv[1]
with open(p) as f:
    c = f.read()
old = '        models = list(cfg.get("presets", {}).keys())'
new = '''        # Only surface *enabled* presets in model pickers. Disabled presets
        # (e.g. the built-in DEFAULT_CONFIG "default" preset, disabled by the
        # VIP patch) stay in the config for explicit selection but must not
        # clutter the picker list (issue #55187 semantics).
        models = [
            name for name, preset in cfg.get("presets", {}).items()
            if preset.get("enabled", True)
        ]'''
if old in c:
    c = c.replace(old, new, 1)
    with open(p, 'w') as f:
        f.write(c)
    print("  ✅ inventory.py 补丁完成")
else:
    print("  ❌ inventory.py 找不到 models 锚点")
    sys.exit(1)
PYEOF
    fi
}

# ============================================================
# model_switch.py — fallback 空串
# ============================================================
patch_model_switch() {
    local MS="$HERMES_REPO/hermes_cli/model_switch.py"
    if grep -q "fall back to no MoA instead" "$MS" 2>/dev/null; then
        echo "  ✓ model_switch.py 已打补丁（git main 自带）"
    else
        echo "  → 补丁 model_switch.py ..."
        python3 - "$MS" << 'PYEOF'
import sys
p = sys.argv[1]
with open(p) as f:
    c = f.read()
old = '                new_model = "default"'
new = '''                # VIP patch 2026-08-05: fallback to built-in "default" preset
                # loaded unsubscribed providers — fall back to no MoA instead.
                new_model = ""'''
if old in c:
    c = c.replace(old, new, 1)
    with open(p, 'w') as f:
        f.write(c)
    print("  ✅ model_switch.py 补丁完成")
else:
    print("  ❌ model_switch.py 找不到 new_model 锚点")
    sys.exit(1)
PYEOF
    fi
}

# ============================================================
# credential_files.py — 媒体路径翻译到 workspace 共享卷（hermes-run 容器可见）
# ============================================================
patch_credential_files() {
    local CF="$HERMES_REPO/tools/credential_files.py"
    if grep -q "VIP patch 2026-08-27: hermes-run container media mapping" "$CF" 2>/dev/null; then
        echo "  ✓ credential_files.py 已打补丁"
    else
        echo "  → 补丁 credential_files.py (to/from_agent_visible_cache_path) ..."
        python3 - "$CF" << 'PYEOF'
import sys
p = sys.argv[1]
with open(p) as f:
    c = f.read()

anchor1 = '    backend = (os.environ.get("TERMINAL_ENV") or "local").strip().lower()'
patch1 = """    # ── VIP patch 2026-08-27: hermes-run container media mapping ──────────
    # Host ~/.hermes media dirs are symlinked into ~/hermes-workspace/tmp/
    # hermes-media (link-media-to-workspace.sh). The hermes-run container
    # sees the workspace, NOT ~/.hermes — map host cache paths to the
    # workspace-visible equivalents before generic backend translation.
    media_root = os.path.join(
        os.path.expanduser("~"), "hermes-workspace", "tmp", "hermes-media"
    )
    if os.path.isdir(media_root):
        home = os.path.expanduser("~")
        h = str(host_path)
        for prefix, sub in (
            (f"{home}/.hermes/cache/images", "images"),
            (f"{home}/.hermes/cache/documents", "documents"),
            (f"{home}/.hermes/cache/audio", "audio"),
            (f"{home}/.hermes/cache/videos", "videos"),
            (f"{home}/.hermes/cache/screenshots", "screenshots"),
            (f"{home}/.hermes/images", "flat-images"),
            (f"{home}/.hermes/attachments", "attachments"),
        ):
            if h.startswith(prefix + "/"):
                return os.path.join(media_root, sub, h[len(prefix) + 1:])

"""
if anchor1 not in c:
    print("  ❌ credential_files.py 找不到 to_agent_visible_cache_path 锚点")
    sys.exit(1)
c = c.replace(anchor1, patch1 + anchor1, 1)

anchor2 = '    if os.environ.get("TERMINAL_ENV", "local") != "docker":'
patch2 = """    # ── VIP patch 2026-08-27: reverse media mapping (container → host) ─────
    media_root = os.path.join(
        os.path.expanduser("~"), "hermes-workspace", "tmp", "hermes-media"
    )
    if os.path.isdir(media_root):
        home = os.path.expanduser("~")
        p = str(container_path)
        for sub, prefix in (
            ("images", f"{home}/.hermes/cache/images"),
            ("documents", f"{home}/.hermes/cache/documents"),
            ("audio", f"{home}/.hermes/cache/audio"),
            ("videos", f"{home}/.hermes/cache/videos"),
            ("screenshots", f"{home}/.hermes/cache/screenshots"),
            ("flat-images", f"{home}/.hermes/images"),
            ("attachments", f"{home}/.hermes/attachments"),
        ):
            if p.startswith(media_root + "/" + sub + "/"):
                return os.path.join(prefix, p[len(media_root) + len(sub) + 2:])

"""
if anchor2 not in c:
    print("  ❌ credential_files.py 找不到 from_agent_visible_cache_path 锚点")
    sys.exit(1)
c = c.replace(anchor2, patch2 + anchor2, 1)

with open(p, 'w') as f:
    f.write(c)
print("  ✅ credential_files.py 补丁完成")

PYEOF
    fi
}

# ============================================================
# 调度
# ============================================================

case "$REQUESTED" in
    all|"")     patch_profiles; patch_moa_config; patch_config_defaults; patch_inventory; patch_model_switch; patch_credential_files ;;
    profiles.py)        patch_profiles ;;
    moa_config.py)      patch_moa_config ;;
    config_defaults.py) patch_config_defaults ;;
    inventory.py)       patch_inventory ;;
    model_switch.py)    patch_model_switch ;;
    credential_files.py) patch_credential_files ;;
    *)
        echo "❌ 未知补丁名: $REQUESTED"
        echo "   可用: profiles.py moa_config.py config_defaults.py inventory.py model_switch.py credential_files.py all"
        exit 1
        ;;
esac

# 清 .pyc（只清对应文件目录）
find "$HERMES_REPO" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find "$HERMES_REPO" -name '*.pyc' -delete 2>/dev/null || true

echo ""
echo "✅ 补丁完成: $REQUESTED"
