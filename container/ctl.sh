#!/bin/bash
# ================================================================
# hermes-container-ctl — unified container control layer (docker | apple)
# 唯一分叉点：DRIVER 差异表。上层代码（hermes-run, guard, install）共用。
# 部署: /usr/local/bin/hermes-container-ctl  (Linux: docker, macOS: container CLI)
# 用法:
#   ctl exec [--no-net] <cmd...>     在容器内执行命令（stdin 管道, 防注入）
#   ctl create [--no-net]            按 config.yaml 创建并启动容器
#   ctl start|stop|rm <name>         容器生命周期
#   ctl rebuild [--no-net]           重建（stop+rm+create+start）
#   ctl build                        从 Dockerfile 构建镜像
#   ctl list                         列出容器
#   ctl status                       状态 + 隔离自检
# ================================================================
set -u

CTL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── DRIVER 差异表（唯一分叉点）──────────────────────────────────
detect_driver() {
    local drv="${HERMES_CONTAINER_DRIVER:-}"
    if [ -z "$drv" ]; then
        case "$(uname -s)" in
            Darwin) drv="apple" ;;
            *)      drv="docker" ;;
        esac
    fi
    echo "$drv"
}

DRIVER="$(detect_driver)"

case "$DRIVER" in
    docker)
        CLI="docker"
        SUDO_PREFIX=""                                    # docker 组即可，无需提权前缀
        EXEC_USER_FLAG="-u $(id -u):$(id -g)"             # 宿主 UID 映射，文件属主正确
        BUILD_ARCH_FLAG=""                                # docker 宿主架构
        LIST_ALL_CMD=("$CLI" ps -a --format '{{.Names}}')
        LIST_RUNNING_CMD=("$CLI" ps --format '{{.Names}}')
        SYS_START=""                                      # dockerd 常驻，无需启动
        ;;
    apple)
        REAL_USER="${SUDO_USER:-$(stat -f '%Su' /dev/console 2>/dev/null || echo '')}"
        [ -z "$REAL_USER" ] && REAL_USER="${USER:-}"
        CLI="container"
        SUDO_PREFIX="sudo -u $REAL_USER"                  # container CLI per-user (XPC)
        EXEC_USER_FLAG=""                                 # 继承 Mac 用户
        BUILD_ARCH_FLAG="--arch amd64"                    # Apple container 默认 arm64 不可用
        LIST_ALL_CMD=("$SUDO_PREFIX" "$CLI" list --quiet --all)
        LIST_RUNNING_CMD=("$SUDO_PREFIX" "$CLI" list --quiet)
        SYS_START="$SUDO_PREFIX $CLI system start"
        ;;
    *)
        echo "Error: unknown driver '$DRIVER' (HERMES_CONTAINER_DRIVER=docker|apple)" >&2
        exit 1
        ;;
esac

# ── 配置读取（config.yaml sandbox 段）────────────────────────────
CFG="${VIP_CFG:-$HOME/.hermes/plugins/hermes-vip/config.yaml}"

# 输出: name image memory_mb cpus workdir vols retry_intervals
read_config() {
    python3 - "$CFG" <<'PYEOF'
import os, sys, yaml
cfg_path = sys.argv[1]
c = {}
try:
    c = yaml.safe_load(open(cfg_path)) or {}
except Exception:
    c = {}
sb = c.get('sandbox', {})
cont = sb.get('container', {})
name = cont.get('name', 'hermes-vm')
image = cont.get('image', 'hermes-vm:latest')
mem = cont.get('memory_mb', 2048)
cpu = cont.get('cpus', 2)
workdir = sb.get('workdir', '/hermes-workspace')
vols = []
for m in sb.get('mounts', []):
    h = os.path.expandvars(os.path.expanduser(m.get('host_path', '')))
    g = os.path.expandvars(os.path.expanduser(m.get('container_path', '')))
    if not h or not g:
        continue
    r = ':ro' if not m.get('writable', True) else ''
    vols.append(f'-v {h}:{g}{r}')
retry = sb.get('retry', {}).get('intervals', [2, 60, 600])
print(name)
print(image)
print(mem)
print(cpu)
print(workdir)
print(' '.join(vols))
print(' '.join(str(x) for x in retry))
PYEOF
}

read_config_vals() {
    local cfg_out
    cfg_out=$(read_config)
    CN=$(echo "$cfg_out" | sed -n '1p')
    IMG=$(echo "$cfg_out" | sed -n '2p')
    MEM=$(echo "$cfg_out" | sed -n '3p')
    CPU=$(echo "$cfg_out" | sed -n '4p')
    WORKDIR=$(echo "$cfg_out" | sed -n '5p')
    VOLS=$(echo "$cfg_out" | sed -n '6p')
    RETRY_INT=$(echo "$cfg_out" | sed -n '7p')
}

# ── exec：容器内执行（平台无关核心）──────────────────────────────
cmd_exec() {
    local no_net=0 cname
    [ "${1:-}" = "--no-net" ] && no_net=1 && shift
    [ $# -eq 0 ] && echo "Usage: ctl exec [--no-net] <command>" >&2 && exit 1
    read_config_vals
    cname="$CN"
    [ "$no_net" = "1" ] && cname="${CN}-no-net"

    # apple: 确保 container system 在跑
    if [ -n "$SYS_START" ] && ! pgrep -q container-apiserver 2>/dev/null; then
        $SYS_START >/dev/null 2>&1 || { echo "Error: failed to start container system" >&2; exit 1; }
        for _i in 1 2 3 4 5; do pgrep -q container-apiserver 2>/dev/null && break; sleep 1; done
    fi

    # 生命周期：运行中 / 已停止 / 不存在
    local running=""
    running=$("${LIST_RUNNING_CMD[@]}" 2>/dev/null | grep -x "$cname") || true
    if [ -z "$running" ]; then
        if "${LIST_ALL_CMD[@]}" 2>/dev/null | grep -x "$cname" >/dev/null; then
            $SUDO_PREFIX $CLI start "$cname" 2>&1
        else
            echo "Error: container $cname does not exist. Run 'ctl create [--no-net]' first." >&2
            exit 1
        fi
    fi

    # trap + PID marker（^C 转发到容器内）
    local marker="/tmp/hrm-$$.pid"
    cleanup() {
        echo "" >&2
        echo "  ^C received, terminating..." >&2
        $SUDO_PREFIX $CLI exec -i "$cname" sh -c "kill \$(cat $marker 2>/dev/null) 2>/dev/null; rm -f $marker" 2>/dev/null || true
        exit 1
    }
    trap cleanup INT TERM

    local cmd="$*"
    local input
    input=$(printf '%s\n' \
        "echo \$\$ > $marker" \
        "cd $WORKDIR 2>/dev/null || cd \$HOME/hermes-workspace 2>/dev/null || true" \
        "$cmd" \
        "rc=\$?; rm -f $marker; exit \$rc")

    exec_once() {
        echo "$input" | $SUDO_PREFIX $CLI exec -i $EXEC_USER_FLAG "$cname" sh 2>&1
        return ${PIPESTATUS[1]:-0}
    }

    local rc
    exec_once; rc=$?
    [ "$rc" -eq 0 ] && exit 0
    # Only retry exec-layer failures (docker rc=125); command failures (1-127)
    # are the container command's own exit code and must NOT trigger retries.
    if [ "$rc" -ne 125 ]; then
        exit "$rc"
    fi
    local delay
    for delay in $RETRY_INT; do
        echo "Warning: exec connection failed, retrying in ${delay}s..." >&2
        sleep "$delay"
        exec_once; rc=$?
        [ "$rc" -eq 0 ] && exit 0
        [ "$rc" -ne 125 ] && exit "$rc"
    done
    echo "Error: exec connection failed after retries, $cname may need manual restart" >&2
    exit 1
}

# ── create：按 config 创建并启动（create+start 替代 run, 避开 registry 验证）──
cmd_create() {
    local no_net=0 net_flag="" cname
    [ "${1:-}" = "--no-net" ] && no_net=1 && shift
    read_config_vals
    cname="$CN"
    if [ "$no_net" = "1" ]; then
        cname="${CN}-no-net"
        net_flag="--network none"
    fi
    echo "Creating $cname ($IMG) mem=${MEM}MiB cpus=$CPU driver=$DRIVER"
    $SUDO_PREFIX $CLI stop "$cname" 2>/dev/null || true
    $SUDO_PREFIX $CLI rm "$cname" 2>/dev/null || true
    sleep 1
    $SUDO_PREFIX $CLI create --name "$cname" --memory "${MEM}MiB" --cpus "$CPU" \
        $BUILD_ARCH_FLAG $net_flag $VOLS "$IMG" sleep infinity
    $SUDO_PREFIX $CLI start "$cname"
    echo "Done: $cname running"
}

cmd_rebuild() {
    local no_net=0
    [ "${1:-}" = "--no-net" ] && no_net=1
    cmd_create $([ "$no_net" = "1" ] && echo --no-net)
}

cmd_build() {
    local dockerfile="${CTL_DIR}/Dockerfile.hermes-vm"
    [ -f "$dockerfile" ] || dockerfile="${CTL_DIR}/macos/Dockerfile.hermes-vm"
    read_config_vals
    echo "Building image $IMG from $dockerfile (driver=$DRIVER)"
    $SUDO_PREFIX $CLI build $BUILD_ARCH_FLAG -t "$IMG" -f "$dockerfile" "$(dirname "$dockerfile")"
}

cmd_list() {
    "${LIST_ALL_CMD[@]}" 2>/dev/null || echo "(no containers)"
}

cmd_status() {
    read_config_vals
    echo "driver=$DRIVER  container=$CN image=$IMG"
    echo "--- running ---"
    if "${LIST_RUNNING_CMD[@]}" 2>/dev/null | grep -x "$CN" >/dev/null; then
        echo "  $CN: running"
    else
        echo "  $CN: not running"
    fi
    if "${LIST_RUNNING_CMD[@]}" 2>/dev/null | grep -x "${CN}-no-net" >/dev/null; then
        echo "  ${CN}-no-net: running"
    else
        echo "  ${CN}-no-net: not running"
    fi
}

# ── 入口 ──────────────────────────────────────────────────────
case "${1:-}" in
    exec)    shift; cmd_exec "$@" ;;
    create)  shift; cmd_create "$@" ;;
    rebuild) shift; cmd_rebuild "$@" ;;
    build)   shift; cmd_build "$@" ;;
    list)    shift; cmd_list "$@" ;;
    status)  shift; cmd_status "$@" ;;
    start)   shift; $SUDO_PREFIX $CLI start "${1:-hermes-vm}" ;;
    stop)    shift; $SUDO_PREFIX $CLI stop "${1:-hermes-vm}" ;;
    rm)      shift; $SUDO_PREFIX $CLI rm "${1:-hermes-vm}" ;;
    *)
        echo "Usage: $0 {exec|create|rebuild|build|list|status|start|stop|rm} [--no-net] [args...]" >&2
        exit 1
        ;;
esac
