#!/bin/bash
# ================================================================
# Hermes Container Isolation — Orchestration Script
# 统一管理脚本: start / stop / upgrade / shell / logs / status
#
# 用法:
#   ./hermes-container.sh start      启动容器
#   ./hermes-container.sh stop       停止容器
#   ./hermes-container.sh upgrade    重建镜像 + 重启
#   ./hermes-container.sh shell      进入容器 shell
#   ./hermes-container.sh logs       查看日志
#   ./hermes-container.sh status     检查隔离状态
# ================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINER_NAME="hermes-agent"
IMAGE_NAME="hermes-isolated"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}⚠️ $1${NC}"; }

# ── 前置检查 ──────────────────────────────────────────────────
check_prereqs() {
    command -v docker &>/dev/null || fail "Docker 未安装"
    [ -f "$SCRIPT_DIR/config.yaml" ] || fail "config.yaml 不存在，从 config.template.yaml 复制并填入配置"
    [ -f "$SCRIPT_DIR/Dockerfile" ] || fail "Dockerfile 不存在"
    [ -f "$SCRIPT_DIR/docker-compose.yml" ] || fail "docker-compose.yml 不存在"
}

# ── 构建镜像 ──────────────────────────────────────────────────
build() {
    echo "━━━ 构建镜像 ━━━"
    docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
    pass "镜像构建完成"
}

# ── 启动 ──────────────────────────────────────────────────────
start() {
    check_prereqs
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        warn "容器已在运行"
        return 0
    fi
    # 确保 config.yaml 存在
    if [ ! -f "$SCRIPT_DIR/config.yaml" ]; then
        cp "$SCRIPT_DIR/config.template.yaml" "$SCRIPT_DIR/config.yaml"
        warn "已创建 config.yaml 模板，请编辑后重新启动"
        return 1
    fi
    # 挂载 config.yaml 到 docker-compose 期望的位置
    export CONFIG_SOURCE="$SCRIPT_DIR/config.yaml"
    build
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d
    sleep 3
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        pass "容器已启动 → ws://127.0.0.1:19119"
        echo "  Desktop 远程网关配置:"
        echo "    URL:   http://127.0.0.1:19119"
        echo "    Token: hermes-container-token-2026"
    else
        fail "容器启动失败，查看日志: docker logs $CONTAINER_NAME"
    fi
}

# ── 停止 ──────────────────────────────────────────────────────
stop() {
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" down 2>/dev/null || true
    pass "容器已停止"
}

# ── 升级 ──────────────────────────────────────────────────────
upgrade() {
    echo "━━━ 升级容器 ━━━"
    stop
    docker build --no-cache -t "$IMAGE_NAME" "$SCRIPT_DIR"
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d
    sleep 3
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        pass "升级完成 → ws://127.0.0.1:19119"
    else
        fail "升级后启动失败，查看日志: docker logs $CONTAINER_NAME"
    fi
}

# ── Shell ─────────────────────────────────────────────────────
shell() {
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        docker exec -it "$CONTAINER_NAME" bash
    else
        fail "容器未运行，先 start"
    fi
}

# ── 日志 ──────────────────────────────────────────────────────
logs() {
    docker logs -f "$CONTAINER_NAME"
}

# ── 状态检查 ──────────────────────────────────────────────────
status() {
    echo "━━━ 容器状态 ━━━"
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        pass "容器运行中"
        echo ""
        echo "━━━ 进程 UID ━━━"
        docker exec "$CONTAINER_NAME" id
        echo ""
        echo "━━━ 隔离验证 ━━━"
        echo -n "  读 /etc/shadow: "
        docker exec "$CONTAINER_NAME" cat /etc/shadow 2>&1 | head -1 || echo "(shadow 内容)"
        echo -n "  读 ~/.ssh: "
        docker exec "$CONTAINER_NAME" ls /home/_hermes/.ssh 2>&1 || true
        echo -n "  sudo: "
        docker exec "$CONTAINER_NAME" sudo whoami 2>&1 || true
        echo ""
        echo "━━━ 暴露端口 ━━━"
        docker port "$CONTAINER_NAME"
    else
        warn "容器未运行"
    fi
}

# ── 入口 ──────────────────────────────────────────────────────
case "${1:-}" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; start ;;
    upgrade) upgrade ;;
    shell)   shell ;;
    logs)    logs ;;
    status)  status ;;
    build)   build ;;
    *)
        echo "用法: $0 {start|stop|restart|upgrade|shell|logs|status|build}"
        exit 1
        ;;
esac