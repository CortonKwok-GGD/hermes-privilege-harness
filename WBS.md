# Hermes Privilege Harness — WBS

> 项目工作分解 + 踩坑记录。完成任务后更新状态，不清除历史。

---

## 项目概况

```
名称：    Hermes Privilege Harness (hermes-privilege-harness)
简称：    VIP (Verified Interface Process)
目标：    LLM 只有一个提权通道：vip_sudo → 原生审批卡片 → 用户批准 → root
仓库：    https://github.com/CortonKwok-GGD/hermes-privilege-harness
         https://gitee.com/cortonkwok/hermes-privilege-harness
平台：    macOS (Login Items + watchdog) / Linux (systemd)
版本：    v1.0.0
分支：    main（完整版）/ passive-vip（社区 PR 版）
PR：     https://github.com/NousResearch/hermes-agent/pull/63066
状态：    ✅ 本地 Mac 验证 / ✅ 沙箱验证 / 🟡 PR 待 review
```

## 架构演进

| 日期 | 变更 | 细节 |
|------|------|------|
| 2026-07-11 | **方向 C** — 删 bwrap/dangerous | 改为明确的 vip_sudo 路径 |
| 2026-07-11 | **非阻塞 + vip_check** | handler 不阻塞，用 /vip-approve + vip_check 取结果 |
| 2026-07-11 | **`{"action":"approve"}`** — 原生卡片 | 发现 pre_tool_call 可返回 approve 触发 Hermes 原生审批闸门 |
| 2026-07-12 | **方向 C+** — guard.py + sudo_execute | vip_sudo handler 直接调 daemon 的 sudo_execute，去掉审批队列中转 |
| 2026-07-12 | **防循环** | 同命令连续 3 次失败 → 120s 阻断 |
| 2026-07-12 | **session approval** | 插件内存管理，不用 config.yaml 的 allowlist |
| 2026-07-12 | **macOS 26 启动** | launchd exit 5 → 改用 Login Items + watchdog |
| 2026-07-12 | **passive-vip 分支** | 社区版：去掉 active guard，只做 stamp 验证 + daemon 执行 |

---

## 当前架构

### main 分支（完整版）
```
LLM → terminal("sudo xxx") → guard.block → "Use vip_sudo"
LLM → vip_sudo("xxx") → pre_tool_call → {"action":"approve"} → 原生卡片
                     → handler → sudo_execute(socket) → daemon → sudo <cmd> → root
```

### passive-vip 分支（社区版）
```
LLM → vip_sudo("xxx") → pre_tool_call → stamp → {"action":"approve"} → 原生卡片
                     → handler → _verify(stamp) → 有章则执行 → daemon → root
                                            → 无章则 REJECTED
```

### 关键文件

| 文件 | 职责 |
|------|------|
| `hermes-plugin/guard.py` | pre_tool_call 钩子 + vip_sudo handler（main 含防循环/passive 含 stamp） |
| `hermes-plugin/__init__.py` | 插件注册入口 |
| `hermes-plugin/gateway_handler.py` | /vip-pending 命令（仅 main） |
| `daemon/vipd.py` | daemon 主入口 |
| `daemon/socket_server.py` | 双 socket 服务器 (request + control) |
| `daemon/executor.py` | 命令执行器（自动 sudo） |
| `examples/install-macos.sh` | macOS 安装（版本检测 + Login Items + CN Desktop） |
| `examples/install-linux.sh` | Linux 安装（版本检测 + systemd） |

---

## Phase 0: 项目骨架 ✅

| # | 任务 | 状态 |
|---|------|:---:|
| 0.1 | 目录结构 | ✅ |
| 0.2 | WBS | ✅ |
| 0.3 | 模块占位 | ✅ |

## Phase 1: Daemon 核心 ✅

| # | 任务 | 文件 |
|---|------|------|
| 1.1 | socket 通信协议 | `socket_server.py` |
| 1.2 | 审批队列 + TTL | `approval_queue.py` |
| 1.3 | 命令执行器（auto sudo） | `executor.py` |
| 1.4 | 双 socket 服务器 | `socket_server.py` |
| 1.5 | 审计日志 | `audit.py` |
| 1.6 | 主入口 | `vipd.py` |

## Phase 2: Plugin ✅

| # | 任务 | 文件 |
|---|------|------|
| 2.1 | plugin.yaml | `plugin.yaml` |
| 2.2 | 守卫 (pre_tool_call) | `guard.py` |
| 2.3 | vip_sudo handler | `guard.py` |
| 2.4 | 防循环机制 | `guard.py`（main only） |
| 2.5 | session 审批状态 | `guard.py`（main only） |
| 2.6 | stamp 验证 | `guard.py`（passive-vip only） |
| 2.7 | 注册入口 | `__init__.py` |
| 2.8 | /vip-pending 命令 | `gateway_handler.py`（main only） |

## Phase 3: 安装部署 ✅

| # | 任务 | 文件 |
|---|------|------|
| 3.1 | macOS 安装脚本 | `examples/install-macos.sh` |
| 3.2 | Linux 安装脚本 | `examples/install-linux.sh` |
| 3.3 | Hermes 版本检测 (>= 0.18) | 两个脚本 |
| 3.4 | CN Desktop 路径检测 | `install-macos.sh` |
| 3.5 | Login Items + watchdog | `install-macos.sh` |

## Phase 4: 发布 🟡

| # | 任务 | 状态 |
|---|------|:---:|
| 4.1 | 双语 README | ✅ |
| 4.2 | WBS 更新 | ✅ |
| 4.3 | Gitee 仓库 + master 清理 | ✅ |
| 4.4 | GitHub 仓库 + 双语同步 | ✅ |
| 4.5 | passive-vip 分支创建 | ✅ |
| 4.6 | GitHub PR #63066 (NousResearch) | ✅ 已提交 |
| 4.7 | 代码中文注释全英文化 | ✅ |
| 4.8 | PR squash 为单 commit | ✅ |
| 4.9 | 沙箱重装部署 | ✅ |
| 4.10 | 待上游 review 反馈 | 🟡 |

---

## 2026-07-12 今日关键动作

### 沙箱重装 (10.0.0.3)
1. **备份**：tinc 配置 + Hermes .env/config 备份到 `~/hermes-workspace/backups/sandbox-tinc-20260712/`
2. **无影桌面黑屏** → `runtime-gui-uos.service` failed (exit 127) → 缺 `libQt5Widgets/libQt5Gui/libgoogle-glog` → `apt install` 恢复 → GUI OK
3. **admin NOPASSWD sudo 测试** → 去掉后阿里云依赖破裂 → 恢复 `/etc/sudoers.d/eds-sudoers`
4. **Hermes 安装** → pip 版（缺 desktop）vs git 版（有 desktop）→ PATH 优先级修复 `~/.hermes/bin/:$PATH`
5. **VIP 部署** → systemd 初版 `NoNewPrivileges=yes` 导致 daemon 无法 sudo → 去掉安全限制 → daemon active
6. **hermes-vip daemon ConfigDirectory 权限** → systemd 期望 700 vs 实际 755 → `chmod 700` 修复

### passive-vip 分支 & PR
7. **分支创建** → `git checkout -b passive-vip` → guard.py 从 203→143 行，去 active guard
8. **stamp 验证** → `_stamp()/_verify()` 防止越权直接调 handler
9. **PR 提交** → fork `CortonKwok-GGD/hermes-agent` → branch `plugin-privilege-harness` → PR #63066
10. **三次 force push** → 1) 中文→英文代码；2) main→passive 版本错误；3) squash 单 commit
11. **plugin.yaml 挑错** → PR 里是旧版（v0.1.0 + post_tool_call），修正为 v1.0.0 + pre_tool_call only
12. **examples/ 丢失** → force push 时遗漏，重新补回

### GitHub 仓库管理
13. **master 分支清理** → 覆盖为 main 内容，设 main 为默认
14. **代理克隆** → `ALL_PROXY=socks5://10.0.0.5:8888` 绕过 GitHub 直连超时

---

## 踩坑记录

### 1. Lambda 参数不匹配 (2026-07-11)

**现象**：vip_sudo handler 调用 daemon 时报 "daemon closed connection"

**根因**：Hermes v0.18.2 的 `register_tool` handler 接收 dict（`handler=lambda args, **kw: ...`），而不是 kwargs。参数名错了导致 command 被当作空字符串传给 daemon。

**修复**：`handler=lambda args, **kw: guard.vip_sudo(args.get("command",""), ...)`

### 2. `return_immediately` 绕过原生卡片 (2026-07-11)

**现象**：用了 2 天时间做非阻塞文本审批卡（/vip-approve + vip_check），结果用户抱怨"只有一个选项"。

**发现**：Hermes v0.18 的 `pre_tool_call` 支持第三个返回值 `{"action":"approve"}`，触发原生交互审批闸门（方向键选择 / 网关按钮）。

**教训**：先查 Hermes 源码（`hermes_cli/plugins.py:_get_pre_tool_call_directive_details`），再设计。不要猜 API。

### 3. `rule_key` 写进 config.yaml 的越权风险 (2026-07-12)

**现象**：加 `rule_key` 后原生卡片出现 "always" 选项，选了写进 `~/.hermes/config.yaml`。admin 用户可读写它 → 注入代码能直接加 allowlist → 绕过审批。

**修复**：每次 `rule_key` 随机生成 (`vip:sudo:<uuid>`)，写入的 key 下个会话失效。外加插件内存管理 session 审批。

### 4. executor 没加 sudo → 命令无 root 权限 (2026-07-12)

**现象**：沙箱测试 `vip_sudo("apt-get remove htop")` 报 "Permission denied"。daemon 以 hermes-vip 运行但命令没带 sudo。

**修复**：executor 自动前置 `sudo`，并 strip LLM 可能传入的 `sudo` 防嵌套。

### 5. macOS 26.5.2 launchd exit 5 (2026-07-12)

**现象**：`sudo launchctl load` / `bootstrap` / `enable+load` 全部 exit 5。daemon 直接跑 `sudo /usr/local/bin/hermes-vipd` 正常。

**原因**：macOS 26+ 系统级 LaunchDaemon 的 `load` 损坏。原 gateway 修复（PR #62223）只适用于用户级 LaunchAgent。

**修复**：放弃 launchd，改用 Login Items + watchdog 脚本。重启后自动启动，watchdog 每 10 秒检查并自动恢复。

### 6. _hermesvip 读不到 daemon 代码 → 崩溃循环 (2026-07-12)

**现象**：watchdog 启动 daemon → 立即 crash → 10 秒后重启 → crash → 无限循环。

**根因**：`/usr/local/lib/hermes-vip/` 属主 `root:wheel 644`，`_hermesvip` 不是 wheel 组，读不了 Python 模块。

**修复**：安装脚本加 `chmod -R 755 /usr/local/lib/hermes-vip/`。

### 7. watchdog 工作目录不可达 (2026-07-12)

**现象**：watchdog 以 mac 身份运行 `sudo -u _hermesvip vipd` 时继承 mac 的 cwd，`_hermesvip` 访问不到 `/Users/mac/...`→ `getcwd: Permission denied`

**修复**：watchdog 内 `start_daemon()` 先 `cd /tmp`。

### 8. Hermes Desktop CN 版路径不同 (2026-07-12)

**现象**：插件装到 `~/.hermes/plugins/` 不生效。

**原因**：Desktop CN 版的 hermes-home 是 `~/Library/Application Support/cn.org.hermesagent.desktop/runtime/hermes-home/`。

**修复**：安装脚本检测 CN Desktop 路径，自动安装到正确位置。

### 9. 老专代码审计发现 HIGH 越权 (2026-07-12)

- `_session_approved = True` 在 handler 开始时设置 → 连接 daemon 失败也标记为已批准 → 后续 vip_sudo 不弹卡
- `json.dumps(req).encode()` 调两遍 → 协议一致性风险
- `_recv_all` 未校验长度 → 数据不完整时静默错误

全部已修。

### 10. CLI 版本升级注意事项 (2026-07-12)

- brew 版 `/opt/homebrew/bin/hermes` 是包装脚本 → 需要替换为指向 Desktop v0.18 binary 的 wrapper
- Desktop `desktop-bin/hermes` 是版本包装器 → Desktop 升级时需同步更新
- 用户 `.zshrc` 可能有 `alias hermes=...` → 需一并更新

### 11. 沙箱 systemd `NoNewPrivileges=yes` 阻断 sudo (2026-07-12)

**现象**：沙箱部署后 vip_sudo 报 "Permission denied"。`sudo -u hermes-vip sudo whoami` 正常 → daemon 内 sudo 失败。

**根因**：systemd service 文件有 `NoNewPrivileges=yes`，阻止进程通过 `execve(sudo)` 提权。

**修复**：去掉 service 文件所有安全限制（NoNewPrivileges / ProtectSystem / ProtectHome），只留最基本的 `RuntimeDirectory`。

### 12. 沙箱无影桌面 GUI 崩溃 (2026-07-12)

**现象**：重启后桌面黑屏，鼠标不可用。

**根因**：`runtime-gui-uos.service` failed (exit 127)。`ldd` 发现缺少 `libQt5Widgets.so.5` / `libQt5Gui.so.5` / `libglog.so.0`——之前测试时误删了 ubuntu-server 包连带移除了 Qt5 依赖。

**修复**：`apt install libqt5widgets5 libqt5gui5 libgoogle-glog0v5`。

### 13. PR 文件版本混乱 (2026-07-12)

**现象**：PR 第一个 commit 推了 main 版代码（203 行 + gateway_handler + 中文注释），第二个 commit 换 passive-vip 但 plugin.yaml 却是旧版（v0.1.0 + post_tool_call），第三个 commit 翻译注释时又有文件被 overwrite。

**根因**：本地 `git checkout main` 恢复后忘记切回 passive-vip，执行 `cp` 时用了 main 的文件。

**修复**：`git reset --soft origin/main` + 全部重新复制 → squash 为单 commit → force push。

### 14. GitHub 克隆超时 (2026-07-12)

**现象**：`git clone git@github.com:...` 持续 timeout。

**根因**：国内直连 GitHub TCP 握手缓慢。

**修复**：用新加坡 VPS 的 SOCKS5 代理：`ALL_PROXY=socks5://10.0.0.5:8888 git clone`。

---

## 2026-07-13 安全加固

### Stamp 验证（defense-in-depth）

**背景**：Desktop 原生版审批卡在 gateway notify 未注册时可能静默回退到 `submit_pending` 队列——如果 `resolve_pre_tool_block` 在此路径有 bug，handler 会在无用户审批的情况下执行。

**修复**：从 `passive-vip` 分支的 stamp/verify 模式中提取 defense-in-depth 机制合并到 main 分支：

- `check()` 返回前先 `_stamp(command)` 盖章
- `vip_sudo()` handler 入口处 `_verify(command)` 验章——无章直接 REJECTED
- 印章 30s TTL，单次消费
- `_session_approved=True` 路径也盖章（免审批卡但验章链不跳过）

详见 guard.py 完整重写。

### 权限最小化

| 维度 | 修复前 | 修复后 |
|------|--------|--------|
| socket 权限 | 0666（任意进程可连） | 0660 `_hermesvip:daemon` |
| mac 用户 | 不在 daemon 组 | 加入 daemon 组 |
| `_hermesvip` 多余组 | `_lpoperator`/`localaccounts`/sharepoint | `dseditgroup -d` 清理（部分受 SIP 保护删不掉，安全影响低） |
| 废弃 launchd plist | 残留 /Library/Launch{Daemon,Agent}s/ | 安装脚本清理 |

### 安装脚本 v3.0

- 开发和部署路径完全分离

| 用途 | 路径 |
|------|------|
| git 仓库 | `~/hermes-workspace/apps/hermes-vip/` |
| daemon 安装 | `/usr/local/lib/hermes-vip/` |
| daemon 入口 | `/usr/local/bin/hermes-vipd` |
| plugin 安装 | `~/.hermes/plugins/hermes-vip/` |
| watchdog | `~/.hermes/scripts/hermes-vipd-watchdog.sh` |

- daemon wrapper 修复：`cd /tmp; HOME=/var/empty` 避免 `_hermesvip` 的 cwd 权限问题
- daemon 用系统 Python 3.9 (`/usr/bin/python3`)，只依赖 stdlib

---

## 待讨论

| # | 议题 | 状态 |
|---|------|:---:|
| D1 | `_session_approved` 改为 per-session_id 管理（多用户场景） | 🔴 |
| D2 | 等待上游 PR #63066 review 反馈 | 🟡 |
| D3 | daemon socket 目录权限 macOS vs Linux 差异 | ✅ |
| D4 | 微信网关 + vip_sudo 完整测试 | 🔴 |
| D5 | Desktop gateway notify 回退至 submit_pending 时的审批卡丢失 | 🟡 待上游沟通 |
| D6 | `_hermesvip` 创建时阻止 macOS 自动加入 _lpoperator 等组 | 🔴 |
| D7 | daemon 层 blocklist 检查（当前只在 guard 层做） | 🔴 |
|| D8 | stamp key 改为 SHA-256 摘要（消除 120 字符前缀碰撞风险） | 🔵 低优 |
|| D9 | MCP server bwrap 包装方案 | 🔵 Pending |

---

## 2026-07-18 v8.0 — 源头开关 (Source Switch)

### 核心转变

v7.x 所有方案（`_hermes` 用户、Docker 容器、三层 wrapper）都是**把 Hermes 塞进沙箱**。

v8.0 翻转视角：**让 LLM 的工具调用默认在沙箱里执行，要出来才需审批。**

### 当前架构（三条路）

```
                      ┌─ 子进程（terminal, execute_code）
                      │   → bwrap 包装，透明放行（无审批）
                      │
所有工具 ──────────────┼─ 进程内函数（read_file, write_file, patch, search_files, vision_analyze）
                      │   → block → "Use terminal: cat/echo/sed/grep..."
                      │
                      ├─ 数据工具（todo, memory, skill_*, cronjob, project_*, ...）
                      │   → 放行（不碰文件系统）
                      │
                      ├─ 未知工具（browser_*, web_search, MCP, 未来工具...）
                      │   → block → "Use vip_sudo"
                      │
                      └─ 出口（vip_sudo）
                          → 审批卡（唯一需要用户批准的工具）
```

### 文件结构（2026-07-20）

```
~/.hermes/plugins/hermes-vip/
├── config.yaml     ← 用户可编辑：沙箱开关、网络开关、挂载目录、vip_sudo开关
├── sandbox.py      ← 沙箱检测、bwrap 包装、config 读写
├── guard.py        ← check() 三条路分发 + vip_sudo handler + blocklist
├── __init__.py     ← 注册入口 + /sandbox /vipsudo /vipdaemon 三个 slash command
├── blocklist.yaml
└── plugin.yaml
```

### 系统提示 (pre_llm_call, 四个状态)

| sandbox | vip_sudo | network | 系统提示 |
|:---:|:---:|:---:|---|
| ON | ON | ON | 沙箱内。Terminal 无审批。vip_sudo 唯一需审批 |
| ON | ON | OFF | 同↑ + 网络已隔离 |
| ON | OFF | — | 沙箱内。Terminal 无审批。vip_sudo 关了，找用户 /vipsudo on |
| OFF | ON | — | 沙箱关了。vip_sudo 可用 |
| OFF | OFF | — | 全开放。系统 sudo 正常 |

### 关键决策

1. **不按工具名分类，按执行形态分类** — 子进程（bwrap 可包）vs 进程内函数（不能包）
2. **没有白名单、没有 mount 列表补偿** — 能包进 bwrap 的就包，不能包的就 block
3. **MCP 工具归属未知工具 → block → Use vip_sudo** — MCP 也是子进程，但 bwrap 包装方案待实现（D9）
4. **execute_code 和 terminal 一样是子进程** — 之前漏了，现在也包 bwrap
5. **network: false 默认隔离网络** — 用户可用 `/sandbox net on` 开启
6. **所有开关写 config.yaml** — `/sandbox off` 持久化，新对话生效

### 沙箱验证沙箱

- 10.0.0.3 Ubuntu 22.04
- bwrap 隔离：SSH 密钥不可读 ✅、/etc/shadow 不存在 ✅、sudo 不可用 ✅
- 网络隔离：--unshare-net 生效 ✅、/sandbox net on 可解除 ✅
- VIP plugin：30 个工具分类全部正确 ✅
- 所有开关持久化到 config.yaml ✅
- Daemon socket 权限 0o750 ✅（修复了 SOCKET_DIR_MODE=0o700 的 bug）

---

## macOS 实施计划

### 现状

| 功能 | Linux (10.0.0.3) | macOS (本地) | 差距 |
|:---|:---:|:---:|:---|
| 子进程 bwrap 沙箱 | ✅ | ❌ macOS 无 bwrap | 需替代方案 |
| 网络隔离 | ✅ | ❌ | 同上级 |
| guard.py 三条路 | ✅ | ✅ 逻辑共享 | 无差距 |
| vip_sudo 提权 | ✅ | ✅ Login Items + watchdog | 无差距 |
| slash command | ✅ | ✅ | 无差距 |
| config.yaml | ✅ | ✅ | 无差距 |

### 选型分析

macOS 有两个方向实现沙箱：

| 方案 | 原理 | 优点 | 缺点 |
|:---|:---|:---|:---|
| **A. sandbox-exec** | Apple 内核级 Seatbelt 沙箱，SBPL 配置文件定义权限 | 内核级隔离，Apple 原生 | SBPL 配置复杂，缺少文档，网络隔离难控制 |
| **B. launch + soft limit** | 让子进程以受限用户身份运行，文件权限靠 OS ACL | 实现简单，无依赖 | 不如内核隔离严格，网络隔离靠 pf |
| **C. 跳过沙箱，仅用 vip_sudo** | guard.py 检测到 macOS 时跳过子进程包装 | 零改动 | macOS 上无沙箱保护 |

**推荐方案：C 优先 + A 后续**

v8.0 的架构本身是跨平台的——`guard.py` 的判断逻辑（执行形态分类）在 macOS 上完全适用。只是 `sandbox.py` 的 `build_bwrap_cmd()` 返回 None（bwrap 不存在），沙箱功能自动关闭，guard 回退到只做 vip_sudo 拦截。

### 实施步骤

#### Phase 1: VIP 插件在 macOS 上跑通 ❌→✅

| # | 任务 | 文件 | 说明 |
|:---|------|------|------|
| 1.1 | guard.py 跨平台检查 | `guard.py` | `sandbox.in_sandbox()` 返回 None 时正常放行，不报错 |
| 1.2 | sandbox.py macOS 安全降级 | `sandbox.py` | `build_bwrap_cmd()` 在 bwrap 不可用时返回原命令 |
| 1.3 | 测试 plugin 加载 | `__init__.py` | 确保 slash command 注册、pre_tool_call hook 正常 |
| 1.4 | 测试 vip_sudo 审批链 | — | 审批卡 → daemon → root, 端到端走通 |
| 1.5 | 测试 guard 工具分类 | — | terminal 放行、read_file 放行（无 bwrap 时不拦） |

#### Phase 2: macOS 原生沙箱 (sandbox-exec) ⬜→✅

| # | 任务 | 文件 | 说明 |
|:---|------|------|------|
| 2.1 | 研究 sandbox-exec SBPL 配置 | `sandbox.py` | 编写 macOS.sb 配置文件：tmpfs home、网络控制、只读系统目录 |
| 2.2 | 替换 bwrap 调用 | `sandbox.py` | 检测到 macOS 时走 `sandbox-exec -f profile.sb -- command` |
| 2.3 | 网络隔离 | `sandbox.py` | SBPL 中 deny network-outbound，/sandbox net 切换 |
| 2.4 | 跨平台 config.yaml | `config.yaml` | macOS 和 Linux 共用一份配置 |
| 2.5 | 端到端测试 | — | bwrap 等价隔离验证 |
| 2.6 | 更新 macOS 安装脚本 | `install-macos.sh` | 添加 sandbox-exec 依赖（macOS 自带无需安装） |

### Phase 1 的状态

> Pending — 等待开始


---

## 2026-07-13 v3.2+v3.3 — 审批缓存重构 & 黑名单

### 审批缓存：从 VIP 自缓存 → Hermes 原生

**问题链**：
- v3.0: `_session_approved` 在 handler ec==0 后设 True → **用户选 once 也被记住** ❌
- v3.1: 删 `_session_approved`，加 `_last_success` 5min TTL → **同 bug，once 也 TTL** ❌
- v3.2: 完全删掉所有 VIP 层缓存，`check()` 每次都返回 approve ✅
- 审批缓存完全由 Hermes 原生机制管理：`approve_session()` (Session) 和 `command_allowlist` (Always)
- `rule_key` 从随机 UUID 改为固定 `"vip:sudo"`，使 Hermes 原生 session/always 机制生效
- 用户选 Run(once) → 下次必弹卡。选 Session → 进程内免卡。选 Always → 永久免卡

**老专架构分析**（2026-07-13）：handler 拿不到用户的 choice (once/session/always)。这是在 Hermes 架构下的根本约束。VIP 不应自行缓存——任何猜测都会出错。

### 黑名单 (v3.3)

- **配置文件**: `/usr/local/etc/hermes-vip/blocklist.yaml`（YAML，16条规则）
- **热加载**: 60s 缓存，`_load_blocklist()` 自动重读
- **Fail-closed**: 文件丢失/损坏/YAML错误 → 加载硬编码 `_FALLBACK_BLOCKLIST`（10条核心规则）
- **权限**: macOS SIP 限制为 `root:wheel 644`，Linux 设 `root:daemon 640`
- **消息**: blocked 时提示用户手动在终端执行，不直接拒绝

### SSH 远程 sudo 放行

- `_SSH_REMOTE_RE` 匹配 `ssh [opts] [user@]host cmd`
- SSH 远程命令中的 sudo 不拦截，由 SSH 认证负责远端安全

### 老专代码审计结果

2026-07-13 审计发现（已全部修复）：
1. ✅ 5 条 blocklist 高危绕过（参数交换、替代工具、管道写入等）→ 已修复 16 条规则
2. ✅ blocklist fail-open → 改为 fail-closed（硬编码 fallback）
3. 🟡 SSH ProxyCommand 本地 sudo 绕过 → 分析后确认：需要本机 NOPASSWD（已不存在）+ SSH 凭证
4. ✅ blocklist.yaml 信息泄露 → macOS SIP 限制，Linux 设 640
5. 🔵 Stamp 前缀碰撞 → 低风险，标记为 D8 待讨论

### stamp TTL

15s（从 30s 缩短）。handler 在审批后立即同步执行，15s 足够宽裕。

---

## 2026-07-14 — Git Push 保护（终版）

### 最终方案

两路并行的审批方案，不造轮子，全部利用 Hermes 原生能力：

| 命令 | 检测方式 | 审批 | 执行 |
|------|---------|------|------|
| `git push` | VIP `__init__.py` 注入 `DANGEROUS_PATTERNS` | Hermes 原生审批卡（`display_target=命令本身`） | terminal 直接执行 |
| `sudo xxx` | VIP `guard.py` 的 `pre_tool_call` block | → LLM 换 `vip_sudo` → 审批卡（`description=sudo: xxx`） | daemon 提权执行 |

### 注入方式

`hermes-plugin/__init__.py` 的 `_inject_git_push_pattern()`：
```python
from tools.approval import DANGEROUS_PATTERNS, DANGEROUS_PATTERNS_COMPILED
DANGEROUS_PATTERNS.append((r'(?:^|[;&|&(])\s*git\s+push\b', "git push (requires approval)"))
```

Hermes 原生检测路径的 `display_target` = 原始命令，所以卡上能看到完整命令，不像插件审批路径的硬编码 `<tool_name> (plugin approval rule)`。

### 已知问题

- Hermes Desktop 渲染层叠问题：DeepSeek 长思考时 streaming "思考中..." 文本可能覆盖审批卡 description 区域，属于上游问题
- `sudo` 不能用注入方案，因为没有 TTY 输密码，必须走 daemon 提权

### 文件变更

| 文件 | 变更 |
|------|------|
| `hermes-plugin/__init__.py` | 新增 `_inject_git_push_pattern()`；修复非 ASCII 字符语法错误 |
| `hermes-plugin/guard.py` | git push 放行（由 Hermes 原生处理）；`vip_sudo` message 简化为 `sudo:`；保留 sudo block + stamp/verify/blocklist |
| `tests/test_git_push_protection.py` | 新增（25 项验证） |
| `tests/test_laozhuan_fixes.py` | 新增（SHA-256 stamp / loop JSON / ReDoS） |

### 后续规划

| # | 议题 | 优先级 |
|---|------|:-----:|
| G1 | PAT/Deploy Key 方案：物理层保护 SSH 写权限 | 🔵 待定 |
| G2 | `vip_git` 专用工具 | 🔵 待定 |
| G3 | Desktop 审批卡渲染层叠问题（思考中覆盖 description） | 🔵 上游跟踪 |


## 2026-07-21 — Workspace 权限修复（Docker 终端兼容）

### 问题

Hermes Desktop Docker 后台以 `_hermes` 用户运行，但工作目录文件属组为 `staff`，`_hermes` 不在 `staff` 组 → 无法 git commit / 写文件。

### 根因

file 属组 `staff`(gid=20) vs `_hermes` 在 `admin`(gid=80)。

### 修复

两安装脚本新增 section 9:

- 创建 `hermes-shared` 共享组
- 加 `REAL_USER` + `_hermes` 到该组
- `chgrp -R hermes-shared ~/hermes-workspace && chmod -R g+rwX`
- `~/.hermes/` 不在 workspace 下，天然不受影响

只涉及安装脚本，不影响运行时权限模型。