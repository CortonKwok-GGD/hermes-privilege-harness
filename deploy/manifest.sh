#!/bin/bash
# ================================================================
# deploy/manifest.sh — 部署映射单一事实源 (被 install.sh / update.sh 引用)
#
# 定义两类映射:
#   1. GENERATED: repo 路径 → 部署路径 (由 install.sh 实际变量展开)
#   2. DEPLOYED.json: 安装时记录 repo→部署→sha256 快照, update.sh 据此比对
#
# 用法: source deploy/manifest.sh; gen_deployed_json <output_path>
# ================================================================
set -euo pipefail

# ── 生成部署清单: 记录 repo→部署→sha256 ──
# 输入环境变量: PROJECT_DIR VIP_LIB VIP_ETC VIP_RUN VIP_LOG CTL_BIN RUN_BIN VIPD_BIN
#               PLUGIN_DIR BLOCKLIST_FILE (平台由 deploy/platform.sh 提供)
# 注意: 调用前必须 source deploy/platform.sh (需要 IS_MAC/IS_LINUX 判断服务单元)
gen_deployed_json() {
    local out="${1:-$VIP_LIB/DEPLOYED.json}"
    [ -n "${PROJECT_DIR:-}" ] || { echo "manifest.sh: PROJECT_DIR 未设置"; return 1; }
    [ -n "${VIP_LIB:-}" ] || { echo "manifest.sh: VIP_LIB 未设置"; return 1; }
    [ -n "${PLUGIN_DIR:-}" ] || { echo "manifest.sh: PLUGIN_DIR 未设置"; return 1; }

    python3 - "$out" <<'PYEOF'
import hashlib, json, os, sys

out = sys.argv[1]
# repo 相对路径 -> 部署绝对路径 (生成时用 shell 实际变量)
repo_root = os.environ["PROJECT_DIR"]
mapping = [
    # daemon
    ("daemon/audit.py",             os.path.join(os.environ["VIP_LIB"], "daemon/audit.py")),
    ("daemon/approval_queue.py",    os.path.join(os.environ["VIP_LIB"], "daemon/approval_queue.py")),
    ("daemon/executor.py",          os.path.join(os.environ["VIP_LIB"], "daemon/executor.py")),
    ("daemon/socket_server.py",     os.path.join(os.environ["VIP_LIB"], "daemon/socket_server.py")),
    ("daemon/vipd.py",              os.path.join(os.environ["VIP_LIB"], "daemon/vipd.py")),
    # 插件 (config.yaml 是用户配置, 排除)
    ("hermes-plugin/__init__.py",   os.path.join(os.environ["PLUGIN_DIR"], "__init__.py")),
    ("hermes-plugin/guard.py",      os.path.join(os.environ["PLUGIN_DIR"], "guard.py")),
    ("hermes-plugin/gateway_handler.py", os.path.join(os.environ["PLUGIN_DIR"], "gateway_handler.py")),
    ("hermes-plugin/plugin.yaml",   os.path.join(os.environ["PLUGIN_DIR"], "plugin.yaml")),
    ("hermes-plugin/sandbox/__init__.py", os.path.join(os.environ["PLUGIN_DIR"], "sandbox/__init__.py")),
    # 容器控制
    ("container/ctl.sh",            os.environ["CTL_BIN"]),
    ("container/hermes-run.sh",     os.environ["RUN_BIN"]),
    ("container/Dockerfile.hermes-vm", os.path.join(os.environ["VIP_LIB"], "Dockerfile.hermes-vm")),
    # 服务模板
    # config.yaml / blocklist.yaml 是用户配置: install 时生成/更新, 但 update.sh
    # 不比对 repo 模板(apply 会用模板覆盖丢失 trusted_user / 用户自定义 blocklist)
    ("examples/config.yaml",        os.path.join(os.environ["VIP_ETC"], "config.yaml")),
    ("examples/blocklist.yaml",     os.environ["BLOCKLIST_FILE"]),
]

def sha(p):
    try:
        with open(p, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except Exception:
        return None

# 用户配置文件: 只记录部署侧, 不参与 repo 比对 (apply 不得用模板覆盖)
USER_CONFIG = {
    "examples/config.yaml",
    "examples/blocklist.yaml",
}

files = {}
for rel, dep in mapping:
    repo_path = os.path.join(repo_root, rel)
    r = sha(repo_path)
    d = sha(dep)
    if r is None and d is None:
        continue
    entry = {
        "deployed_path": dep,
        "repo_sha256": r,
        "deployed_sha256": d,
    }
    if rel in USER_CONFIG:
        entry["track_repo"] = False
        entry["user_config"] = True
    files[rel] = entry

# 平台: 服务单元文件路径不同 (由 platform.sh 变量判断)
svc = ""
if os.environ.get("IS_LINUX") == "1":
    svc = "/etc/systemd/system/hermes-vipd.service"
elif os.environ.get("IS_MAC") == "1":
    svc = "/Library/LaunchDaemons/com.hermes.vipd.plist"
if svc and os.path.exists(svc):
    files["service_unit"] = {
        "deployed_path": svc,
        "repo_sha256": None,  # 模板路径因平台而异, 不比对 repo
        "deployed_sha256": sha(svc),
        "track_repo": False,  # 只记录部署侧, 不参与 repo 比对
    }

data = {
    "format": 1,
    "repo_root": repo_root,
    "generated_at": __import__("time").strftime("%Y-%m-%d %H:%M:%S"),
    "files": files,
}
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w") as f:
    json.dump(data, f, indent=2)
print("DEPLOYED.json ->", out, f"({len(files)} files)")
PYEOF
}

# ── 校验清单存在且格式正确 ──
deployed_json_valid() {
    local p="$1"
    [ -f "$p" ] && python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$p" 2>/dev/null
}
