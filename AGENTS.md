# Hermes VIP — AI Agent Guide

> v9.1: terminal commands run in a container. vip_sudo is the only way out.
> 统一 ctl：docker 语义两端一致（Linux 原生 docker，macOS 用 Colima 提供 dockerd）。

## Quick Start (for a new agent session)

1. Read this file — it's the project map
2. Check `/vipsandbox` and `/vipsudo` in chat for current state
3. For version history and known issues, see WBS.md

## 架构（v9.1 unified ctl）

```
LLM calls tool
  → guard.check() — 路由
    ├─ terminal → sandbox.build_sandbox_cmd() → hermes-run → hermes-container-ctl → docker exec
    ├─ vip_sudo → stamp → approval card → daemon socket → executor
    └─ data tools (memory, skill_*, etc.) → pass through
```

**唯一分叉点 = container/ctl.sh 的 DRIVER 差异表**（docker | apple）：
- docker：CLI=docker，EXEC_USER_FLAG="-u $(id -u):$(id -g)"，EXEC_ENV="-e HOME=$HOME"
- apple：CLI=container（Apple Virtualization.framework），SUDO_PREFIX="sudo -u REAL_USER"，BUILD_ARCH_FLAG="--arch amd64"

平台目标：**两端都用 docker**（Linux 原生 docker daemon；macOS 用 Colima 提供 VM 内 dockerd）。
apple driver 保留为兼容/回退，计划退役。

## 挂载语义（config 一份两端通用）

`hermes-plugin/config.yaml` 是单一事实源：

```yaml
sandbox:
  enabled: true
  network: true
  workdir: $HOME/hermes-workspace
  container:
    name: hermes-vm
    image: hermes-vm:latest
    memory_mb: 2048
    cpus: 2
    root_persist_dirs: [/etc, /root, /home, /usr/local, /opt, /var/lib, /var/cache, /var/log, /srv]
  mounts:
    - host_path: $HOME/hermes-workspace          # rw 双向同步（容器↔宿主）
      container_path: $HOME/hermes-workspace
      writable: true
    - host_path: $HOME/.hermes/config.yaml        # ro
    - host_path: $HOME/.hermes/plugins/hermes-vip/config.yaml  # ro
    - host_path: $HOME/.hermes/profiles           # ro
    - host_path: $HOME/hermes-vm-root             # 根持久化（见下）
      container_path: /
      writable: true
vip_sudo:
  enabled: true
```

**根持久化（docker 无法挂 /，OCI 硬限制）**：
- apple driver：hermes-vm-root 直挂 /（根替换）
- docker driver：ctl.sh 自动展开为 root_persist_dirs 列表（-v hermes-vm-root/<dir>:<dir>），
  首次 create 时 init_system_dirs() 从镜像 cp -a + chown 宿主 UID（.ctl-init 标记）
- 容器内 uid = 宿主 UID（EXEC_USER_FLAG），挂载源 chown 后 1001 可写 /etc /root 等
- **装包（apk add）容器内被禁**（uid 1001 无权限，实测）→ 装包走镜像层（Dockerfile RUN apk add）

## Key paths (host → deployed)

| Dev repo | Deployed to |
|----------|------------|
| `container/ctl.sh` | `/usr/local/bin/hermes-container-ctl` |
| `container/hermes-run.sh` | `/usr/local/bin/hermes-run` |
| `hermes-plugin/*` | `~/.hermes/plugins/hermes-vip/` |
| `daemon/*` | `/usr/local/lib/hermes-vip/` |
| `daemon/vipd.py` | `/usr/local/bin/hermes-vipd` |

## Slash commands

| Command | Effect |
|---------|--------|
| `/vipsandbox on/off` | Toggle sandbox |
| `/vipsandbox net on/off` | Toggle network (--network none 双容器) |
| `/vipsudo on/off` | Toggle vip_sudo tool |
| `/vipdaemon` | Check daemon via socket |

## Known issues / 决策记录 (2026-08-05)

1. **重试语义**: ctl.sh 只对 exec 层错误 (docker rc=125) 重试；容器内命令 rc 直接透传
   （旧版对 rc≠0 重试 2s/60s/600s，whoami 失败会卡 11 分钟）
2. **ctl build 必须 -t**: 否则镜像无 tag，create 时 docker 去 registry 拉（403/超时）
3. **docker 挂 / 被 OCI 拒绝**（"destination can't be '/'"），podman/runc 同样
   → 根持久化用系统目录展开（方案1）；multipass 不选（无 KVM + snap 渠道断 + alpine 无 cloud-init）
4. **Mac 端 Colima 方向（2026-08-05 定）**: brew install colima docker && colima start，
   提供 VM 内 dockerd + 标准 docker CLI → ctl.sh driver=docker 两端一致。
   对比 Apple container: 每容器一 VM (2×2G 配额) vs Colima 单 VM 2G 配额（省一半配额，
   内存按需非满占）。待 Mac 实测: 挂载性能(virtiofs)、实际 RSS、--network none。
5. **CLI 非交互 chat 里 vip_sudo 审批卡崩**（interrupt_queue）— 完整审批链路需 Desktop/交互环境
6. **guard 提权检测（#2）**: 高置信=行首提权词（_HIGH_CONF_PRIVILEGE_RE），低置信（echo 数据/
   mid-line/subshell）放行容器（容器内 uid 1001 无提权效果，安全）；SSH 远程排除
7. **transform hook（#1）**: transform_terminal_output 给 terminal 结果加前缀
   `[hermes-run container sandbox] net=on/off ...`，LLM 回复不复述标注，验证看 tool result
8. **数据容器假阳性（cdb35de 遗产）**: _is_inert_data_write 只放行完全闭合 cat/tee heredoc、
   echo 单引号；python3 heredoc 非 inert（写代码文件用 sudo 占位 + 替换，或 base64）

## Dev Rules

- **Dev in repo, deploy via dd/install script** — never edit deployed files directly
- **验证机 = 167**（hermes-test@192.168.1.167, Ubuntu 24.04, docker 29 + hermes-vm 容器）；
  所有破坏性/修改操作先在 167 验证再上 Mac
- **167 网络**: docker.io 直连超时 → /etc/docker/daemon.json registry-mirrors:
  docker.1panel.live / docker.m.daocloud.io；snapcraft/PPA 不通（装不了 snap/ppa 包）
- **macOS 26 SIP**: /usr/local/bin/ 写保护 — 用 `dd if=src of=dst`
- **Git push**: VS Codium / Mac 命令行；共享卷 git 由 Agent 做，用户只 push；push 前查 remote
- **测试**: guard 逻辑单测 /tmp/test_guard.py（10/10）；tests/ 目录测试在容器环境
  in_sandbox() 短路 check() 是既有问题（测试设计给非沙箱环境）

## Key Files Reference

| File | Purpose |
|------|---------|
| `container/ctl.sh` | 统一容器控制（driver 表 + 展开 + 初始化） |
| `container/hermes-run.sh` | hermes-run 薄封装（ctl exec [--no-net]） |
| `hermes-plugin/guard.py` | 路由 + vip_sudo handler + 高置信提权检测 |
| `hermes-plugin/__init__.py` | 注册 hooks/tools/slash + transform 标注 |
| `hermes-plugin/sandbox/__init__.py` | 统一 build_sandbox_cmd / config |
| `daemon/*` | Unix socket + executor（共享，两分支相同） |

---
See README.md for human overview, WBS.md for version history and lessons learned.
