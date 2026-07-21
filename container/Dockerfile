# Hermes Container Isolation
# 统一 Dockerfile — macOS (OrbStack) + Linux (Docker/podman) 通用
#
# 构建: docker build -t hermes-isolated .
# 运行: docker compose up -d
# 升级: docker compose down && docker build --no-cache -t hermes-isolated . && docker compose up -d

FROM ubuntu:22.04

LABEL org.hermes.isolation.version="1.0"
LABEL org.hermes.description="Hermes Agent in isolated container"

# ── 系统依赖（国内镜像加速）──────────────────────────────────
# 阿里云 apt 镜像
RUN sed -i 's|http://archive.ubuntu.com|http://mirrors.aliyun.com|g' /etc/apt/sources.list && \
    sed -i 's|http://security.ubuntu.com|http://mirrors.aliyun.com|g' /etc/apt/sources.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    python3.11 \
    python3.11-venv \
    python3-pip \
    ca-certificates \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# python3 → python3.11
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1

# ── _hermes 用户 ──────────────────────────────────────────────
RUN useradd -r -u 996 -s /bin/bash -m -d /home/_hermes _hermes

# ── venv + hermes-agent（清华 pip 镜像）─────────────────────────
USER _hermes
WORKDIR /home/_hermes
RUN python3 -m venv /home/_hermes/venv && \
    /home/_hermes/venv/bin/pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple && \
    /home/_hermes/venv/bin/pip install --no-cache-dir hermes-agent

# ── HERMES_HOME ───────────────────────────────────────────────
RUN mkdir -p /home/_hermes/.hermes/skills /home/_hermes/.hermes/memory /home/_hermes/.hermes/sessions /home/_hermes/.hermes/cron
ENV HERMES_HOME=/home/_hermes/.hermes
ENV PATH="/home/_hermes/venv/bin:$PATH"

# ── 入口 ──────────────────────────────────────────────────────
# serve 模式（headless）+ session token，Desktop 远程网关连接
EXPOSE 9119
CMD ["hermes", "serve", "--port", "9119", "--host", "127.0.0.1"]