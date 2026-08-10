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
        # config 显式配置优先（Mac+Colima → docker）
        local cfg="${VIP_CFG:-$HOME/.hermes/plugins/hermes-vip/config.yaml}"
        drv=$(python3 - "$cfg" <<'PYEOF' 2>/dev/null
import os, sys, yaml
try:
    c = yaml.safe_load(open(sys.argv[1])) or {}
    print(c.get('sandbox', {}).get('container', {}).get('driver', ''))
except Exception:
    print('')
PYEOF
)
    fi
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
    HERMES_DRIVER="$DRIVER" python3 - "$CFG" <<'PYEOF'
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
driver = os.environ.get('HERMES_DRIVER', 'docker')
rpd = cont.get('root_persist_dirs', [])
for m in sb.get('mounts', []):
    h = os.path.expandvars(os.path.expanduser(m.get('host_path', '')))
    g = os.path.expandvars(os.path.expanduser(m.get('container_path', '')))
    if not h or not g:
        continue
    if g == '/' and driver == 'docker':
        # docker 不允许 bind mount 到 /: 展开为系统目录挂载（等价根持久化）
        for d in rpd:
            vols.append(f'-v {h}{d}:{d}')
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
print(' '.join(str(x) for x in rpd))
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
    RPD=$(echo "$cfg_out" | sed -n '8p')
}

# ── exec：容器内执行（平台无关核心）──────────────────────────────
cmd_exec() {
    # daemon 存活探测 (docker driver): 区分"运行时没起" vs "容器缺失",
    # 避免重启后(Colima 未自启)误报 container does not exist。
    # daemon 不可达 = 快速失败给可操作命令, 不进 2s/60s/600s 重试。
    if [ "$DRIVER" = "docker" ]
    then
        if ! docker info >/dev/null 2>&1
        then
            echo "Error: Docker daemon not reachable (sandbox runtime down)." >&2
            if [ -d /System/Library/CoreServices ]
            then
                echo "Fix: colima start   (auto-start at login: brew services start colima)" >&2
            else
                echo "Fix: sudo systemctl start docker   (or: systemctl enable --now docker)" >&2
            fi
            exit 1
        fi
    fi
    local no_net=0 cname root_user=""
    [ "${1:-}" = "--root" ] && root_user="0:0" && shift
    [ "${1:-}" = "--no-net" ] && no_net=1 && shift
    [ $# -eq 0 ] && echo "Usage: ctl exec [--root] [--no-net] <command>" >&2 && exit 1
    if [ -n "$root_user" ] && [ "$DRIVER" != "docker" ]; then
        echo "Error: --root only supported on docker driver (container CLI has no -u)" >&2
        exit 1
    fi
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

    EXEC_ENV=""
    [ "$DRIVER" = "docker" ] && EXEC_ENV="-e HOME=$HOME"
    exec_once() {
        local user_flag="$EXEC_USER_FLAG"
        [ -n "$root_user" ] && user_flag="-u $root_user"
        echo "$input" | $SUDO_PREFIX $CLI exec -i $EXEC_ENV $user_flag "$cname" sh 2>&1
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
# 初始化系统目录挂载（docker driver: 根挂载展开后首次从镜像 cp + chown）
init_system_dirs() {
    [ "$DRIVER" != "docker" ] && return
    local root_src=""
    root_src=$(python3 - "$CFG" <<'PYEOF'
import os, sys, yaml
c = {}
try:
    c = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    pass
for m in c.get('sandbox', {}).get('mounts', []):
    if m.get('container_path') == '/':
        print(os.path.expandvars(os.path.expanduser(m.get('host_path', ''))))
        break
PYEOF
)
    [ -z "$root_src" ] && return
    [ -f "$root_src/.ctl-init" ] && return
    [ -z "$RPD" ] && { touch "$root_src/.ctl-init"; return; }
    echo "Initializing system dirs under $root_src (first run)..."
    local vols2=""
    for d in $RPD; do
        mkdir -p "$root_src$d"
        vols2="$vols2 -v $root_src$d:/i$d"
    done
    docker run --rm -e RPD="$RPD" -e INIT_UID="$(id -u)" -e INIT_GID="$(id -g)" $vols2 alpine:3.20 sh -c '
        for d in $RPD; do
            cp -a "$d/." "/i$d/" 2>/dev/null || true
            chown -R "$INIT_UID:$INIT_GID" "/i$d" 2>/dev/null || true
        done
        echo INIT_OK'
    touch "$root_src/.ctl-init"
}

cmd_create() {
    local no_net=0 net_flag="" cname
    [ "${1:-}" = "--no-net" ] && no_net=1 && shift
    read_config_vals
    # CPU 上限检测：config 值超过可用 CPU 则下调（167 只有 2 CPU）
    local cpu_limit=2
    cpu_limit=$(nproc 2>/dev/null || echo 2)
    if [ "$CPU" -gt "$cpu_limit" ]; then
        echo "Warning: config cpus=$CPU > available $cpu_limit, using $cpu_limit"
        CPU=$cpu_limit
    fi
    init_system_dirs
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
    [ -f "$dockerfile" ] || dockerfile="/usr/local/lib/hermes-vip/Dockerfile.hermes-vm"
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
        echo "Usage: $0 {exec|create|rebuild|build|list|status|start|stop|rm} [--root] [--no-net] [args...]" >&2
        exit 1
        ;;
esac
