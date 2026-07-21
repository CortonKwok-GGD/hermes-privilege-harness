# Hermes Container Sandbox

跨平台容器沙箱方案，统一 Linux (Docker) 和 macOS (Apple container) 的 LLM 沙箱体验。

## 架构

```
hermes-run [--no-net] <command>
    │
    ├── Linux:   docker exec -i hermes-vm sh  (容器隔离)
    └── macOS:   container exec -i hermes-vm sh  (VM 隔离)
```

## 快速开始

### macOS

```bash
# 前提：安装 Apple container CLI (v1.1.0+)
# 安装
cd macos && ./install.sh

# 验证
hermes-run whoami
hermes-run python3 -c "print(2+2)"
hermes-run --no-net curl -s --max-time 3 https://www.baidu.com
```

### Linux

```bash
# 前提：Docker 已安装
# 构建
docker build -t hermes-isolated .

# 启动
docker compose up -d

# 进入
./hermes-container.sh shell
```

## 配置

`~/.hermes/plugins/hermes-vip/config.yaml` 驱动挂载：

```yaml
sandbox:
  enabled: true
  mounts:
  - path: $HOME/hermes-workspace        # 读写作区
    writable: true
  - path: $HOME/.hermes/plugins/hermes-vip/config.yaml  # VIP 配置（只读）
    writable: false
  - path: $HOME/.hermes/config.yaml     # 主配置（只读）
    writable: false
  network: true                          # true=有网 false=隔离
vip_sudo:
  enabled: true
```

## 安全特性

- **注入防护** — 命令通过 `printf + stdin` 管道传递，杜绝分号/引号逃逸
- **路径隔离** — 仅声明的 mount 路径可见，宿主机其余路径 ENOENT
- **网络隔离** — `--no-net` 创建完全无网络的独立容器
- **状态自明** — LLM 可读 config.yaml 自了解沙箱边界

## 平台差异

| 特性 | Linux | macOS |
|------|-------|-------|
| 运行时 | Docker | Apple container CLI |
| 工作区路径 | `/workspace` | 镜像宿主机路径 |
| 自动启动 | Docker 常驻 | `pgrep + system start` |
| 隔离层级 | 容器 (共享内核) | VM (独立内核) |
| 用户 | `_hermes` | 无（纯容器） |
