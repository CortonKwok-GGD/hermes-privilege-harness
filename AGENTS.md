# Hermes VIP — AI Agent Guide

> v9.2: terminal commands run in a container. vip_sudo is the only way out.
> 统一 ctl：docker 语义两端一致（Linux 原生 docker，macOS 用 Colima 提供 dockerd）。
> 统一部署: deploy/update.sh 增量比对/更新（bash 3.2 兼容），平台差异只在 deploy/platform.sh。

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
**已达成（2026-08-05 Mac 部署完成）**。apple driver 保留为兼容/回退（Mac 上 Apple VM hermes-vm 仍保留）。

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
| `deploy/update.sh` | `/usr/local/bin/hermes-vip-update`（install.sh 生成） |
| `deploy/DEPLOYED.json` | `/usr/local/lib/hermes-vip/DEPLOYED.json`（安装时生成） |

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
   echo 单引号；python3 heredoc 非 inert（写代码文件用 @SU@ 占位 + 替换，或 base64）
9. **Mac 部署完成（2026-08-05）**: Colima + install.sh 全流程通过。driver 从 config
   `sandbox.container.driver: docker` 显式读（HERMES_CONTAINER_DRIVER 环境变量优先，uname 回退）。
   Colima registry mirror 用 **build 前预拉镜像兜底**（docker pull docker.1panel.live/library/alpine:3.20
   + tag），因为 --registry-mirror flag 是 master 未 release、colima.yaml 注入 restart 不重载。
10. **vip_sudo cap 同 uid 多进程互踢(实测 2026-08-30)**: 根因是 stamp_init 旧实现删同 uid 旧 cap,
    多进程先后注册后先注册的 cap 失效(非 daemon 重启旧 cap)。已修复: 多 cap 并存 + TTL 24h + 上限 100。
    daemon 重启后旧会话 REJECTED 属 cap 轮换设计 →
    重启 Hermes。terminal 沙箱不重启即生效（插件每次读 runtime config）。
11. **install.sh 安装期间临时禁沙箱**: sandbox.enabled: false → 容器建好才置 true。
    否则容器未就绪时 Hermes terminal 全锁（"container hermes-vm does not exist"）。
12. **uninstall.sh**: 备份 + 交互逐类删除 + 恢复指引；用户数据（hermes-vm-root）不删只告知位置。
13. **容器磁盘占用**: Apple container 用 `container system df`（df 是 system 子命令）。
14. **git identity**: 容器环境全局 git config 不可靠 → 仓库级 git config user.name/email。
15. **待办(2026-08-05 已完成)**: git push 已执行；重启 Hermes 验 vip_sudo 已通过(root)；Apple hermes-vm 回退 VM 保留待删
16. **重启后 terminal 锁死(2026-08-05 修复)**: Colima 不随开机自启 → docker daemon 不在 → ctl exec 误报
    "container hermes-vm does not exist"。修复: ① install.sh Mac 分支加 `brew services start colima`
    注册登录自启(对齐 Linux systemctl enable docker); ② ctl.sh cmd_exec 加 docker info 存活探测,
    daemon 不可达快速失败并给可操作命令(不进 2s/60s/600s 重试), 区分"运行时没起"vs"容器缺失"。
    遗留: brew services 是 LaunchAgent 依赖登录, 纯 SSH 无 GUI 场景需 LaunchDaemon + sudo -u mac
17. **vip_sudo 审批超时语义(2026-08-05 修复)**: 三层超时 — Hermes 审批卡 gateway_timeout=300s、
    插件 stamp TTL(原 15s 改 300s, 对齐审批卡)、daemon ApprovalQueue TTL(默认 300s)。
    根因: 审批卡还等你批, 插件 stamp 已过期 → _verify 返回 REJECTED → 用户批准了却看到"拒绝"。
    socket_server 区分 timeout/deny 回给 LLM(超时≠拒绝)。resolve() 加 expired 检查(过期批准 not_found)。
18. **运行审计日志(2026-08-05 新增)**: audit.py 曾有死代码(open() 从未调用, audit.log 一行不写)已修复;
    socket_server 补 audit.timeout/execute 调用。hermes-run 每次执行记录 run.log(命令/rc/耗时)。
    两者 FIFO: 超 20MB/10MB 滚动保留 .1, 最旧覆盖。路径: /var/log/hermes-vip/{audit,run}.log。
19. **deploy/update.sh 增量部署(2026-08-05 新增)**: DEPLOYED.json 记录 repo→部署→sha256 快照,
    安装时生成(每用户路径不同, 脚本检测不硬编码)。update.sh auto: init(缺)→check→apply(有差异才同步)。
    check 分类: UPDATE-AVAILABLE / LOCALLY-MODIFIED(apply 前备份 user-bak) / NOT-DEPLOYED。
    config.yaml/blocklist.yaml 是 user-config(track_repo=false), apply 绝不用模板覆盖(保护 trusted_user)。
    repo 位置从清单 repo_root 自动读(wrapper 任意位置调用), 不用传 --repo。
20. **bash 3.2 兼容(2026-08-05)**: macOS 自带 bash 3.2 不支持关联数组 declare -A 和 ${var^^}。
    update.sh 用平行普通数组 + 索引查找; install.sh 已有 IS_MAC/IS_LINUX 分支。验证: docker bash:3.2
    镜像做语法检查(167 拉 bash:3.2), 不能只信 Linux bash 5.x。
21. **apply 权限 bug(2026-08-05 修复)**: update.sh apply 曾无条件 chmod 644, 覆盖 platform_bin_deploy
    的 755 → hermes-run 变 644 → 容器沙箱全锁(Permission denied)。修复: 按部署路径 basename 判断
    (hermes-container-ctl/hermes-run/hermes-vipd/hermes-vip-update → 755, 其余 644)。
22. **容器 runtime 与 hermes-vm-root 边界**: 容器沙箱入口 hermes-run 是**宿主机** /usr/local/bin 的
    (插件生成命令串, docker exec 进容器)。hermes-vm-root 是容器根持久化(Apple driver 直挂 / /
    docker root_persist_dirs 展开), 不是 runtime, 不要对它 chmod/chown。修复宿主工具权限只需动
    /usr/local/bin。

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
- **跨平台验证**: 只测 167(Linux bash 5.x)不够 — Mac 的 bash 3.2 是独立兼容层。
  改脚本后必须 bash:3.2 容器语法检查 + 真实 apply 路径测试(不是只 check)
- **部署纪律**: 用户更新 = `hermes-vip-update` 一条命令(或 bash deploy/update.sh auto)。
  不写平台专用脚本、不硬编码路径 — 平台差异只在 deploy/platform.sh

## Key Files Reference

| File | Purpose |
|------|---------|
| `container/ctl.sh` | 统一容器控制（driver 表 + 展开 + 初始化） |
| `container/hermes-run.sh` | hermes-run 薄封装（ctl exec [--no-net]） |
| `hermes-plugin/guard.py` | 路由 + vip_sudo handler + 高置信提权检测 |
| `hermes-plugin/__init__.py` | 注册 hooks/tools/slash + transform 标注 |
| `hermes-plugin/sandbox/__init__.py` | 统一 build_sandbox_cmd / config |
| `daemon/*` | Unix socket + executor + audit（共享，两分支相同） |
| `deploy/platform.sh` | 平台翻译器（唯一分叉点: dd/cp, launchd/systemd, 用户/组） |
| `deploy/manifest.sh` | 部署映射单一事实源（install.sh 调用生成 DEPLOYED.json） |
| `deploy/update.sh` | 增量比对/更新（auto/init/check/apply, bash 3.2 兼容） |

---
See README.md for human overview, WBS.md for version history and lessons learned.
