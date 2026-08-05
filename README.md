# Hermes VIP — Privilege Harness + Container Sandbox

> Terminal commands run in an isolated container. `vip_sudo` is the only way out.

## What it does

Hermes VIP gives an LLM two things:

1. **Container sandbox** — every terminal command runs through `hermes-run` →
   `hermes-container-ctl` → **docker** (Linux 原生 / macOS 经 Colima 提供 dockerd)。
   No approval needed for normal work.
2. **Privilege gateway** — one audited path to root: vip_sudo → approval card → daemon execution.

## Two versions

| | **main** (full sandbox) | **passive-vip** (PR #63066) |
|---|---|---|
| Sandbox | Container isolation (docker, unified ctl) | None |
| vip_sudo | Stamp + verify + daemon | Stamp + verify + daemon |
| Tool routing | 3-path dispatch | Hermes native |
| Install | install-macos.sh / install-linux.sh | same installer |

## 架构（v9.1 统一 ctl）

```
LLM terminal("cmd")
  → guard.check() → hermes-run cmd → hermes-container-ctl exec
    → docker exec -i hermes-vm sh        ← alpine 容器（UID 映射宿主用户）
      → cmd 在隔离容器内执行，结果带 [hermes-run container sandbox] 标注

LLM vip_sudo("apt install x")
  → guard stamp → Hermes approval card → daemon (Unix socket)
    → executor 以 root 执行            ← 宿主特权，唯一出口
```

**唯一分叉点**：container/ctl.sh 的 DRIVER 表（docker | apple）。
平台目标：两端都用 docker —— Linux 原生 daemon；macOS `brew install colima docker && colima start`。

**挂载（config 一份两端通用）**：
- workspace 独立挂载 rw（容器↔宿主双向同步）
- config.yaml / profiles ro
- hermes-vm-root 根持久化：apple 挂 /；docker 自动展开为系统目录挂载
  (/etc /root /home /usr/local /opt /var/lib /var/cache /var/log /srv) + 首次初始化

## Quick Install（新用户一条命令）

```bash
git clone <repo-url> && cd hermes-privilege-harness
sudo bash install.sh
```

自动完成：检测用户/Hermes(≥0.18.0) → 备份现有部署 → 部署 daemon/插件/ctl/hermes-run →
安装依赖（Linux: apt docker.io + registry mirror；macOS: Homebrew + Colima + docker CLI）→
构建镜像 → 创建双容器（hermes-vm / hermes-vm-no-net）→ 安装 daemon 服务 → 验证。

## Slash Commands

| Command | What it does |
|---|---|
| /vipsandbox on/off | Enable/disable container sandbox |
| /vipsandbox net on/off | Enable/disable network (--network none 双容器) |
| /vipsudo on/off | Enable/disable vip_sudo tool |
| /vipdaemon | Check daemon via socket |

## Key Paths

| Path | What |
|---|---|
| `~/hermes-workspace/apps/hermes-vip/` | Dev repo |
| /usr/local/bin/hermes-container-ctl | Unified container control（deployed from container/ctl.sh） |
| /usr/local/bin/hermes-run | Container entry（deployed from container/hermes-run.sh） |
| /usr/local/bin/hermes-vipd | Daemon entry |
| ~/.hermes/plugins/hermes-vip/config.yaml | Runtime config |
| /var/run/hermes-vip/request.sock | Daemon socket |

## 验证环境

- **167**（hermes-test@192.168.1.167, Ubuntu 24.04, docker 29.1.3 + hermes-vm 双容器）
- Mac 部署（Colima）待执行

---
See [AGENTS.md](AGENTS.md) for the full AI agent guide, [WBS.md](WBS.md) for version history and lessons learned.
