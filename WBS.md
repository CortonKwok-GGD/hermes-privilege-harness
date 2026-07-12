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

## 待讨论

| # | 议题 | 状态 |
|---|------|:---:|
| D1 | `_session_approved` 改为 per-session_id 管理（多用户场景） | 🔴 |
| D2 | 等待上游 PR #63066 review 反馈 | 🟡 |
| D3 | daemon socket 目录权限 macOS vs Linux 差异 | ✅ |
| D4 | 微信网关 + vip_sudo 完整测试 | 🔴 |
