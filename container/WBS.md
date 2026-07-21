# Hermes Container Sandbox — Work Breakdown Structure

> macOS/Linux 统一容器沙箱。每个任务记录状态、产出、代码位置。
> 更新规则：完成任务后更新状态 + 写入产出摘要，不清除历史。

---

## 项目概况

```
名称：    Hermes Container Sandbox
目标：    跨平台容器沙箱（Docker Linux + Apple container macOS）
仓库：    ~/hermes-workspace/hermes-container/
状态：    🟢 已完成
开发纪律：先在开发目录（repo）开发，验证后同步到生产（/usr/local/bin/）
```

---

## 当前进度

```
Phase 1: macOS 容器运行时      ████████████████  7/7 ✅
Phase 2: 配置驱动             ████████████████  4/4 ✅
Phase 3: 安全与状态自明        ████████████████  7/7 ✅
Phase 4: 文档与收尾            ████████████████  4/4 ✅
Phase 5: 经验教训              ████████████████  4/4 ✅

总计: 26/26 ✅
```

---

## Phase 1：macOS 容器运行时

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 1.1 | Apple container CLI 安装 | ✅ 完成 | container v1.1.0 | `/usr/local/bin/container` |
| 1.2 | Alpine 镜像加载 | ✅ 完成 | `alpine:3.20` (amd64) | `macos/Dockerfile.hermes-vm` |
| 1.3 | 镜像构建（python3/curl/git/bash） | ✅ 完成 | `hermes-vm:latest` | `macos/Dockerfile.hermes-vm` |
| 1.4 | 常驻容器自动创建 | ✅ 完成 | 冷启动自动检测+重建 | `macos/hermes-run.sh` |
| 1.5 | 容器系统自动启动 | ✅ 完成 | pgrep + container system start | `macos/hermes-run.sh` |
| 1.6 | --no-net 网络隔离 | ✅ 完成 | hermes-vm-no-net + --network none | `macos/hermes-run.sh` |
| 1.7 | 分号注入防御 | ✅ 完成 | printf + stdin 管道 | `macos/hermes-run.sh` |

## Phase 2：配置驱动

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 2.1 | config.yaml mounts 解析 | ✅ 完成 | pyyaml + Python inline | `macos/hermes-run.sh` |
| 2.2 | 路径镜像挂载 (host=container) | ✅ 完成 | `-v /host/path:/host/path` | `macos/hermes-run.sh` |
| 2.3 | 多 config.yaml 不冲突 | ✅ 完成 | 根据 `$HOME` 相对路径命名 | `macos/hermes-run.sh` |
| 2.4 | network 开关控制 | ✅ 完成 | guard 联动 + --no-net | `guard._build_macos_cmd()` |

## Phase 3：安全与状态自明

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 3.1 | LLM 可读 VIP config | ✅ 完成 | `cat ~/.hermes/plugins/hermes-vip/config.yaml` (ro 挂载) | `config/config.vip.yaml` |
| 3.2 | LLM 可读主 config | ✅ 完成 | `cat ~/.hermes/config.yaml` (ro 挂载) | VIP config mount |
| 3.3 | LLM 自发现沙箱边界 | ✅ 完成 | 从 config 读取 mounts + network + 读写权限 | `_inject()` 系统提示 |
| 3.4 | 注入验证 | ✅ 完成 | 分号/管道/双引号全部封死 | printf + stdin |
| 3.5 | 白名单外路径 | ✅ 完成 | ENOENT | 容器 VM 隔离 |
| 3.6 | 宿主机隔离 | ✅ 完成 | 独立 VM kernel，不可见宿主进程 | Apple Virtualization.framework |
| 3.7 | VIP daemon socket 检测 | ✅ 完成 | `/vipdaemon` 改用 socket 连通性 | `__init__.py` |

## Phase 4：文档与收尾

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 4.1 | 创建 WBS.md | ✅ 完成 | 项目进度 + 经验教训 | `WBS.md` |
| 4.2 | 创建 AGENTS.md | ✅ 完成 | 开发规范 + 踩坑记录 | `AGENTS.md` |
| 4.3 | 清理安装残余 | ✅ 完成 | colima/lima/docker.tgz | /tmp /usr/local/bin |
| 4.4 | 入库 | ✅ 完成 | git commit: `5195aad` | `macos/` + `config/` |

## Phase 5：经验教训

| # | 任务 | 状态 | 踩坑 | 解决方案 |
|---|------|------|------|----------|
| 5.1 | /usr/local/bin/ SIP 保护 | ✅ 记录 | macOS 26 禁止 `cp`/`install`/`tee` 写入 /usr/local/bin/ | 用 `dd if=src of=dst` |
| 5.2 | provenance xattr | ✅ 记录 | root 也无法写入或读取带 `com.apple.provenance` 的文件 | 宿主机终端编辑，不能用 vip_sudo |
| 5.3 | VZ 文件同步 | ✅ 记录 | 容器→宿主机方向文件不同步 | 目录在宿主机创建，文件从容器写；校验用 `diff` |
| 5.4 | container list 无 --filter | ✅ 记录 | `container list` 不支持 Docker 风格的 `--filter name=xxx` | 用 `grep -x` 精确匹配 |
| 5.5 | XPC 绑定 Aqua session | ✅ 记录 | 从 daemon、launchctl asuser、_hermes 都无法调用 container CLI | terminal 工具以 mac 用户执行即可 |
| 5.6 | 多架构镜像 | ✅ 记录 | `docker save` 多架构 index 但缺 blob，container load 失败 | 去掉多余架构引用，只留 amd64 |
| 5.7 | pyyaml 缺失 | ✅ 记录 | macOS 系统 Python 没有 yaml 模块，config 解析静默失败 | `pip3 install pyyaml`（host） |
| 5.8 | 开发纪律 | ✅ 记录 | 直接在 `/usr/local/bin/hermes-run` 改代码，没先在 repo 开发 | 改在 repo 的 `macos/hermes-run.sh`，测试完再 `dd` 部署 |

---

## Phase 5 详情：踩坑记录

### 5.1 macOS 26 /usr/local/bin/ SIP 保护

macOS 26 对 `/usr/local/bin/` 有额外的保护。以下全部失败：

```bash
# ❌ 全部 Permission denied
cp /tmp/hermes-run /usr/local/bin/hermes-run
install -m 755 /tmp/hermes-run /usr/local/bin/hermes-run
tee /usr/local/bin/hermes-run < /tmp/hermes-run
```

唯一成功的方式：

```bash
dd if=/tmp/hermes-run of=/usr/local/bin/hermes-run
```

### 5.2 com.apple.provenance xattr

`~/.hermes/plugins/` 目录及其下所有文件都有 `com.apple.provenance` 扩展属性。
即使用 `vip_sudo`（root）也无法写入或删除。`cp`、`cat >`、`tee` 全部失败。
只能在宿主机终端以 mac 用户身份编辑。

```bash
# ❌ vip_sudo 也写不了
xattr -d com.apple.provenance file  # [Errno 13] Permission denied

# ✅ 宿主机终端直接编辑
cat > ~/.hermes/plugins/hermes-vip/__init__.py << 'EOF'
...
EOF
```

### 5.3 VZ 文件同步

Apple Virtualization.framework 的 virtiofs 文件共享是单向可靠的：
- 宿主机 → 容器：✅ 实时可见
- 容器 → 宿主机：⚠️ 有延迟或不同步

表现：在容器内 `cat > /Users/mac/hermes-workspace/file` 写入了文件，容器内 `ls` 能看到，
但宿主机 `ls` 看不到（`No such file or directory`）。

**对策：**
1. 目录在宿主机创建（`mkdir -p ~/hermes-workspace/hermes-vm-build`）
2. 文件在宿主机写（cat 命令从宿主机终端执行）
3. 校验：分别从容器内和宿主机 `ls` 对比

### 5.4 container list 没有 --filter

```bash
# Docker（✅）
docker ps -a --filter "name=hermes-vm"

# Apple container（❌ Unknown option '--filter'）
container list --quiet --filter "name=hermes-vm"

# Apple container（✅ 替代方案）
container list --quiet --all | grep -x "$CNAME"
```

### 5.5 XPC 绑定用户 Aqua session

`container-apiserver` 通过 XPC Mach 服务通信，只能从 mac 用户的 Aqua GUI session 连接。
以下上下文都无法调用 `container` CLI：

- `_hermes` 用户（已被移除）
- `launchctl asuser 501`（macOS 26 封锁）
- daemon 进程（无 Aqua session）

**终端工具作为 Hermes Desktop 的一部分以 mac 用户运行，是唯一能调用 `container` 的上下文。**

### 5.6 多架构镜像加载

`docker save alpine:latest` 保存的是多架构 index，下载了所有架构的 manifest 引用，
但只下载了当前架构（amd64）的 blob。Apple container 的 `image load` 验证所有引用的 blob 都在。

修：清理 index.json，只保留 amd64 分支：

```python
inner['manifests'] = [m for m in inner['manifests']
    if m.get('platform', {}).get('architecture') == 'amd64']
# 更新 index.json 的 digest 引用
```

### 5.7 pyyaml 依赖

`hermes-run` 脚本用 `python3 -c "import yaml"` 解析 config.yaml。但 macOS 系统 Python 没有 yaml 模块，
导致 `import` 报错、`2>/dev/null` 静默吞掉、VOLUME_ARGS 始终为空。

修：`pip3 install pyyaml`（在宿主机装，因为 hermes-run 在宿主机执行）

### 5.8 开发纪律（本项目的教训）

**本项目的开发流程错误示范：**

```
❌ 直接在 /usr/local/bin/hermes-run 用 dd 写入
❌ 直接在 ~/.hermes/plugins/hermes-vip/ 改代码
❌ 没有先在 repo 目录开发再部署
```

**正确的流程：**

```
✅ 改 repo:   ~/hermes-workspace/hermes-container/macos/hermes-run.sh
✅ 测试:      从 repo 复制到临时位置测试
✅ 部署:      dd if=macos/hermes-run.sh of=/usr/local/bin/hermes-run
```

所有生产文件都由 repo 版本部署，不在生产机器上直接修改。
