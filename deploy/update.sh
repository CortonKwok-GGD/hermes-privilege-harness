#!/bin/bash
# ================================================================
# deploy/update.sh — VIP 增量部署比对/更新 (v1)
#
# 原理: 安装时 install.sh 生成 /usr/local/lib/hermes-vip/DEPLOYED.json
#       记录 repo→部署→sha256 快照。本脚本读它, 与当前 repo 逐文件比对,
#       精确同步差异。每个用户/每台机器的清单不同(路径由安装时实际变量
#       展开), 不硬编码路径。
#
# 用法:
#   deploy/update.sh init [--repo PATH]   生成/重建 DEPLOYED.json (root; 旧安装升级用)
#   deploy/update.sh check [--repo PATH]   只读比对, 普通用户可跑
#   deploy/update.sh apply [--repo PATH]   root 同步差异, 自动重启 daemon
#
# 退出码: 0=无差异, 1=有差异(check 时), 2=错误
# ================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VIP_LIB="${VIP_LIB:-/usr/local/lib/hermes-vip}"
DEPLOYED_JSON="${DEPLOYED_JSON:-$VIP_LIB/DEPLOYED.json}"

# 平台翻译器 (唯一分叉点)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/platform.sh"

# ── 参数 ──
ACTION="${1:-check}"
REPO="${2:-}"
[ "$ACTION" = "init" ] || [ "$ACTION" = "check" ] || [ "$ACTION" = "apply" ] || { echo "用法: $0 {init|check|apply} [--repo PATH]"; exit 2; }
if [ "${REPO:-}" = "--repo" ]; then REPO="${3:-}"; fi
[ -n "$REPO" ] || REPO="$PROJECT_DIR"

# ── init: 生成/重建清单 (旧安装升级; 需要 root 写 VIP_LIB) ──
if [ "$ACTION" = "init" ]; then
    [ "$(id -u)" = "0" ] || { echo "❌ init 需要 root: sudo deploy/update.sh init"; exit 2; }
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/manifest.sh"
    mkdir -p "$VIP_LIB/daemon"
    PROJECT_DIR="$REPO" VIP_LIB="$VIP_LIB" \
        VIP_ETC="${VIP_ETC:-/etc/hermes-vip}" \
        CTL_BIN="${CTL_BIN:-/usr/local/bin/hermes-container-ctl}" \
        RUN_BIN="${RUN_BIN:-/usr/local/bin/hermes-run}" \
        PLUGIN_DIR="${PLUGIN_DIR:-$(eval echo ~${SUDO_USER:-$USER})/.hermes/plugins/hermes-vip}" \
        BLOCKLIST_FILE="${BLOCKLIST_FILE:-/etc/hermes-vip/blocklist.yaml}" \
        gen_deployed_json "$DEPLOYED_JSON"
    chown "$(platform_svc_user)" "$DEPLOYED_JSON" 2>/dev/null || true
    echo "✅ DEPLOYED.json 已生成: $DEPLOYED_JSON"
    echo "   接下来: $0 check --repo $REPO  /  $0 apply --repo $REPO"
    exit 0
fi

# ── 加载清单 ──
if [ ! -f "$DEPLOYED_JSON" ]; then
    echo "❌ 找不到 $DEPLOYED_JSON"
    echo "   请先运行: sudo $0 init --repo $REPO"
    exit 2
fi

# ── 读清单 ──
declare -A DEP_PATH DEP_SHA DEP_TRACK
REPO_ROOT=""
while IFS=$'\t' read -r rel path sha track; do
    if [ "$rel" = "__ROOT__" ]; then REPO_ROOT="$path"; continue; fi
    DEP_PATH["$rel"]="$path"
    DEP_SHA["$rel"]="$sha"
    [ "$track" = "false" ] && DEP_TRACK["$rel"]=0
done < <(python3 - "$DEPLOYED_JSON" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"__ROOT__\t{d.get('repo_root','')}\t-\t-")
for rel, f in d.get("files", {}).items():
    print(f"{rel}\t{f.get('deployed_path','')}\t{f.get('deployed_sha256') or ''}\t{str(f.get('track_repo', True)).lower()}")
PYEOF
)

sha() { python3 -c 'import hashlib,sys;
try: print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())
except Exception: pass' "$1"; }

# ── 比对 ──
DIFF_COUNT=0
report_diff() { # rel status repo_sha dep_sha
    echo "  [${2^^}] $1"
    [ -n "${3:-}" ] && echo "      repo_sha:    ${3:-无}"
    [ -n "${4:-}" ] && echo "      deployed_sha: ${4:-无}"
    DIFF_COUNT=$((DIFF_COUNT+1))
}

compare_file() {
    local rel="$1" dep="${DEP_PATH[$rel]:-}"
    if [ "${DEP_TRACK[$rel]:-1}" = "0" ]; then
        return  # 只记录部署侧, 不参与 repo 比对
    fi
    [ -n "$dep" ] || { report_diff "$rel" "no-mapping"; return; }
    local rsha dsha
    rsha=$(sha "$REPO/$rel")
    dsha=$(sha "$dep")
    if [ -z "$rsha" ] && [ -z "$dsha" ]; then
        return  # 两边都没有(被删)
    fi
    if [ "$rsha" = "$dsha" ]; then
        return  # 一致
    fi
    if [ -z "$dsha" ]; then
        report_diff "$rel" "not-deployed" "$rsha" ""
    elif [ -z "$rsha" ]; then
        report_diff "$rel" "removed-from-repo" "" "$dsha"
    elif [ "$dsha" = "${DEP_SHA[$rel]:-}" ]; then
        # 部署侧与快照一致, repo 更新了 → 可安全 apply
        report_diff "$rel" "update-available" "$rsha" "$dsha"
    else
        # 部署侧被手工改过 → 保守, apply 前需确认
        report_diff "$rel" "locally-modified" "$rsha" "$dsha"
    fi
}

echo "📋 VIP 部署比对 (repo=$REPO)"
echo "   清单: $DEPLOYED_JSON"
echo ""
for rel in "${!DEP_PATH[@]}"; do
    compare_file "$rel"
done

if [ "$DIFF_COUNT" -eq 0 ]; then
    echo "✅ 全部一致, 无需更新"
    exit 0
fi

echo ""
echo "⚠️  $DIFF_COUNT 个文件有差异"
if [ "$ACTION" = "check" ]; then
    echo "   执行 sudo deploy/update.sh apply 同步差异"
    exit 1
fi

# ── apply: root 同步 ──
[ "$(id -u)" = "0" ] || { echo "❌ apply 需要 root: sudo deploy/update.sh apply"; exit 2; }

echo ""
echo "🔧 同步差异文件..."
APPLIED=()
for rel in "${!DEP_PATH[@]}"; do
    # user-config / service_unit: 只记录不更新
    if [ "${DEP_TRACK[$rel]:-1}" = "0" ]; then
        continue
    fi
    dep="${DEP_PATH[$rel]}"
    rsha=$(sha "$REPO/$rel")
    dsha=$(sha "$dep")
    [ "$rsha" = "$dsha" ] && continue
    if [ -z "$rsha" ]; then
        echo "  ⏭  $rel 已从 repo 移除, 跳过 (部署侧保留)"
        continue
    fi
    # 本地被改过的文件: 备份后覆盖
    if [ -n "$dsha" ] && [ "$dsha" != "${DEP_SHA[$rel]:-}" ]; then
        cp -a "$dep" "$dep.user-bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
        echo "  ⚠️  $rel 部署侧有本地修改, 已备份 → 覆盖"
    fi
    # 同步 (统一走平台翻译器: Mac SIP→dd, Linux→cp)
    mkdir -p "$(dirname "$dep")"
    if [ "$IS_MAC" = "1" ]; then
        platform_bin_deploy "$REPO/$rel" "$dep"
        chmod 644 "$dep" 2>/dev/null || true
    else
        cp "$REPO/$rel" "$dep"
        chmod 644 "$dep" 2>/dev/null || true
    fi
    APPLIED+=("$rel")
    echo "  ✅ $rel -> $dep"
done

# ── 更新清单快照 ──
if [ ${#APPLIED[@]} -gt 0 ]; then
    echo ""
    echo "🔄 更新部署清单..."
    python3 - "$DEPLOYED_JSON" "$REPO" <<'PYEOF'
import hashlib, json, sys
p, repo = sys.argv[1], sys.argv[2]
d = json.load(open(p))
def sha(x):
    try:
        return hashlib.sha256(open(x,'rb').read()).hexdigest()
    except Exception:
        return None
for rel, f in d.get("files", {}).items():
    rp = f"{repo}/{rel}"
    f["repo_sha256"] = sha(rp)
    f["deployed_sha256"] = sha(f["deployed_path"])
json.dump(d, open(p, "w"), indent=2)
print("  DEPLOYED.json 已更新")
PYEOF
fi

# ── 重启 daemon (如果 daemon 文件变了) ──
RESTART=0
for rel in "${APPLIED[@]}"; do
    case "$rel" in
        daemon/*) RESTART=1 ;;
    esac
done
if [ "$RESTART" = "1" ]; then
    echo ""
    echo "🔄 重启 vipd daemon..."
    platform_restart_vipd
fi

echo ""
echo "✅ 更新完成"
if [ ${#APPLIED[@]} -gt 0 ]; then
    echo "   ⚠️  插件文件(hermes-plugin/*)变更需重启 Hermes 才生效"
fi
exit 0
