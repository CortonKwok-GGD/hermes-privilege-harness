# Hermes VIP — Work Breakdown Structure

> 项目工作分解。每个任务记录状态、产出、代码位置。
> 更新规则：完成任务后更新状态 + 写入产出摘要，不清除历史。

---

## 项目概况

```
名称：    Hermes VIP (Verified Interface Process)
目标：    Hermes 的 root 提权闸门——LLM 看不到授权确认
仓库：    ~/hermes-workspace/apps/hermes-vip/
发布：    GitHub (待定)
平台：    macOS (launchd) + Linux (systemd)
通道：    复用 Hermes 网关通道（默认）/ 独立 Telegram bot（可选）
状态：    🔴 规划中
```

---

## Phase 0：项目骨架

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 0.1 | 创建目录结构 | ✅ 完成 | 6 个子目录 | `apps/hermes-vip/` |
| 0.2 | 创建 WBS | ✅ 完成 | 本文档 | `WBS.md` |
| 0.3 | 创建核心模块占位 | 🔴 待开始 | Python 包骨架 | `daemon/`, `hermes-plugin/` |

---

## Phase 1：VIP Daemon 核心

### 1.1 Socket 通信协议

设计 VIP daemon 与 Hermes plugin 之间的通信协议。

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 1.1.1 | 定义请求/响应格式 | 🔴 待开始 | 协议文档 | `docs/PROTOCOL.md` |
| 1.1.2 | 定义 socket 路径规划 | 🔴 待开始 | 路径设计 | `daemon/socket_server.py` |

**协议草案：**

```json
// 请求 socket（user 可读）— Hermes Plugin → VIP Daemon
// Unix socket: /var/run/hermes-vip/request.sock (user:staff 755)

{
  "type": "sudo_request",
  "req_id": "a7f2c3d8",
  "command": "brew install node@18",
  "reason": "用户要求安装 Node.js 18",
  "origin": {
    "channel": "weixin",
    "session_key": "wx_abc123"
  },
  "timestamp": 1700000000
}

// → 返回（同步，会阻塞直到审批完成或超时）
{
  "status": "approved" | "denied" | "timeout",
  "stdout": "...",
  "stderr": "...",
  "exit_code": 0
}
```

```json
// 控制 socket（root:600）— 连接器 → VIP Daemon
// Unix socket: /var/run/hermes-vip/control.sock (root:wheel 600)

{
  "type": "approval_response",
  "req_id": "a7f2c3d8",
  "action": "approve" | "deny",
  "connector": "hermes_gateway" | "telegram" | "cli",
  "verified_by": "user_id:telegram_12345",
  "timestamp": 1700000100
}
```

### 1.2 审批队列

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 1.2.1 | 实现 ApprovalQueue 类 | 🔴 待开始 | TTL + 线程安全队列 | `daemon/approval_queue.py` |
| 1.2.2 | 实现 req_id 生成器 | 🔴 待开始 | 8 位随机 hex + 纳秒 | 同上 |
| 1.2.3 | 实现超时自动拒绝 | 🔴 待开始 | 5 分钟 TTL 兜底 | 同上 |
| 1.2.4 | 实现 pending 表持久化 | 🔴 待开始 | JSON 文件兜底（防重启丢失）| `daemon/approval_queue.py` |

### 1.3 命令执行器

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 1.3.1 | 实现 Executor 类 | 🔴 待开始 | subprocess 封装 | `daemon/executor.py` |
| 1.3.2 | stdout/stderr 捕获 | 🔴 待开始 | 带大小限制 | 同上 |
| 1.3.3 | 超时自动 kill | 🔴 待开始 | 可配超时（默认 300s）| 同上 |
| 1.3.4 | 高危命令检测 | 🔴 待开始 | 管道+shell 检测（同 Hermes approvals）| 同上 |

### 1.4 Socket 服务器

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 1.4.1 | 实现请求 socket 服务 | 🔴 待开始 | Unix socket 监听 | `daemon/socket_server.py` |
| 1.4.2 | 实现控制 socket 服务 | 🔴 待开始 | root 独占 socket | 同上 |
| 1.4.3 | 实现请求→队列→等待→返回流程 | 🔴 待开始 | 完整 handler | 同上 |
| 1.4.4 | 多客户端并发支持 | 🔴 待开始 | 线程池 | 同上 |

### 1.5 连接器枢纽

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 1.5.1 | 定义 Connector 基类 | 🔴 待开始 | 接口规范 | `connectors/__init__.py` |
| 1.5.2 | 实现 hermes_gateway 连接器 | 🔴 待开始 | 通过 control socket 通知 | `connectors/hermes_gateway.py` |
| 1.5.3 | 实现 CLI 连接器 | 🔴 待开始 | 终端交互 | `connectors/cli.py` |
| 1.5.4 | 实现 OS dialog 连接器 | 🔴 待开始 | macOS osascript / Linux notify | `connectors/os_dialog.py` |

### 1.6 VIP Daemon 主入口

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 1.6.1 | 实现 vipd.py 主循环 | 🔴 待开始 | 启动→初始化→监听 | `daemon/vipd.py` |
| 1.6.2 | 配置文件加载 | 🔴 待开始 | YAML 配置 | 同上 |
| 1.6.3 | 日志系统 | 🔴 待开始 | 结构化日志 | 同上 |
| 1.6.4 | 审计日志 | 🔴 待开始 | 不可变操作记录 | 同上 |

---

## Phase 2：Hermes Plugin

### 2.1 插件骨架

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 2.1.1 | 创建 plugin.yaml | 🔴 待开始 | 插件清单 | `hermes-plugin/plugin.yaml` |
| 2.1.2 | 创建 \_\_init\_\_.py | 🔴 待开始 | register(ctx) 入口 | `hermes-plugin/__init__.py` |
| 2.1.3 | 实现 register() 函数 | 🔴 待开始 | 注册 vip_sudo 工具 | 同上 |

### 2.2 sudo 拦截层

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 2.2.1 | 拦截 terminal("sudo ...") 命令 | 🔴 待开始 | 命令前缀匹配 | `hermes-plugin/intercept.py` |
| 2.2.2 | 提交 VIP 并伪造 sudo 错误 | 🔴 待开始 | 返回"sudo: a password is required" | 同上 |
| 2.2.3 | 重试时检测 pending 结果 | 🔴 待开始 | pending 表查重 | 同上 |
| 2.2.4 | 自动感知用户当前界面 | 🔴 待开始 | gateway/cli/desktop 检测 | 同上 |

### 2.3 审批命令处理器

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 2.3.1 | 注册 /vip-pending 命令 | 🔴 待开始 | 查待审列表 | `hermes-plugin/gateway_handler.py` |
| 2.3.2 | 注册 /vip-approve <id> 命令 | 🔴 待开始 | 批准指定请求 | 同上 |
| 2.3.3 | 注册 /vip-deny <id> 命令 | 🔴 待开始 | 拒绝指定请求 | 同上 |
| 2.3.4 | 通过 Hermes 现有审批绕过机制 | 🔴 待开始 | 利用现有 /approve 绕过路径 | 同上 |

### 2.4 Kill 文件机制

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 2.4.1 | 实现 kill_sudo 标记检测 | 🔴 待开始 | 文件存在→返回"sudo: not found" | `hermes-plugin/kill.py` |
| 2.4.2 | 安装脚本创建 kill 文件 | 🔴 待开始 | `/etc/hermes-vip/kill_sudo` | `examples/` |

---

## Phase 3：安装部署

### 3.1 macOS launchd

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 3.1.1 | 编写 launchd plist 模板 | 🔴 待开始 | 启动 vipd | `examples/com.hermes.vipd.plist` |
| 3.1.2 | 安装脚本 | 🔴 待开始 | `install.sh` | `examples/install-macos.sh` |

### 3.2 Linux systemd

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 3.2.1 | 编写 systemd service 模板 | 🔴 待开始 | 启动 vipd | `examples/hermes-vipd.service` |
| 3.2.2 | 安装脚本 | 🔴 待开始 | `install.sh` | `examples/install-linux.sh` |

### 3.3 初始配置

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 3.3.1 | 配置模板 | 🔴 待开始 | 默认 config.yaml | `examples/config.yaml` |
| 3.3.2 | 安装引导 | 🔴 待开始 | 交互式初始化 | `examples/setup.sh` |

---

## Phase 4：文档 & 发布

| # | 任务 | 状态 | 产出 | 代码位置 |
|---|------|------|------|----------|
| 4.1 | README.md | 🔴 待开始 | 项目介绍+架构图 | `README.md` |
| 4.2 | INSTALL.md | 🔴 待开始 | 安装指南（macOS/Linux） | `INSTALL.md` |
| 4.3 | CONTRIBUTING.md | 🔴 待开始 | 连接器开发指南 | `CONTRIBUTING.md` |
| 4.4 | SECURITY.md | 🔴 待开始 | 安全模型说明 | `SECURITY.md` |
| 4.5 | GitHub 仓库初始化 | 🔴 待开始 | LICENSE + .gitignore | 根目录 |

---

## 依赖 & 接口

### 内部接口

```
Hermes Plugin ──request.sock──▶ VIP Daemon (approval_queue → executor)
Hermes Plugin ◀──request.sock── VIP Daemon (结果返回)

Connector ──control.sock──▶ VIP Daemon (审批响应)
Connector ◀──(回调/通知)──── VIP Daemon (审批推送)
```

### 外部依赖

| 依赖 | 用途 | 平台 |
|------|------|------|
| Hermes Agent | 插件宿主 | macOS/Linux |
| Python 3.10+ | 运行时 | macOS/Linux |
| launchd | 守护进程管理 | macOS |
| systemd | 守护进程管理 | Linux |
| Telegram Bot API | 可选连接器 | 跨平台 |

---

## 当前进度

```
Phase 0: 项目骨架    ████████████████  3/3 ✅
Phase 1: Daemon 核心  ████████████░░░░  12/16 ✅
Phase 2: Plugin      █████████░░░░░░░  7/12 ✅
Phase 3: 安装部署    ████░░░░░░░░░░░░  3/6 🟡
Phase 4: 文档发布    ██████░░░░░░░░░░  3/5 🟡

总计: 28/42 ✅
```

## 已完成的任务

| # | 任务 | 状态 | 代码位置 |
|---|------|------|----------|
| 0.1 | 创建目录结构 | ✅ 完成 | `apps/hermes-vip/` |
| 0.2 | 创建 WBS | ✅ 完成 | `WBS.md` |
| 0.3 | 创建核心模块占位 | ✅ 完成 | 各 __init__.py |
| 1.1.1 | 定义请求/响应格式 | ✅ 完成 | `docs/PROTOCOL.md` |
| 1.1.2 | 定义 socket 路径规划 | ✅ 完成 | `daemon/socket_server.py` |
| 1.2.1 | 实现 ApprovalQueue 类 | ✅ 完成 | `daemon/approval_queue.py` |
| 1.2.2 | 实现 req_id 生成器 | ✅ 完成 | `daemon/approval_queue.py` |
| 1.2.3 | 实现超时自动拒绝 | ✅ 完成 | `daemon/approval_queue.py` |
| 1.2.4 | 实现 pending 表持久化 | ✅ 完成 | `daemon/approval_queue.py` |
| 1.3.1 | 实现 Executor 类 | ✅ 完成 | `daemon/executor.py` |
| 1.3.2 | stdout/stderr 捕获 | ✅ 完成 | `daemon/executor.py` |
| 1.3.3 | 超时自动 kill | ✅ 完成 | `daemon/executor.py` |
| 1.3.4 | 高危命令检测 | ✅ 完成 | `daemon/executor.py` |
| 1.4.1 | 实现请求 socket 服务 | ✅ 完成 | `daemon/socket_server.py` |
| 1.4.2 | 实现控制 socket 服务 | ✅ 完成 | `daemon/socket_server.py` |
| 1.4.3 | 请求→队列→等待→返回流程 | ✅ 完成 | `daemon/socket_server.py` |
| 1.4.4 | 多客户端并发支持 | ✅ 完成 | `daemon/socket_server.py` |
| 1.5.1 | 定义 Connector 基类 | ✅ 完成 | `connectors/__init__.py` |
| 1.5.2 | 实现 hermes_gateway 连接器 | ✅ 完成 | `connectors/hermes_gateway.py` |
| 1.5.3 | 实现 CLI 连接器 | ✅ 完成 | `connectors/cli.py` |
| 1.5.4 | OS dialog 连接器 | 🟡 占位 | `connectors/os_dialog.py` |
| 1.6.1 | 实现 vipd.py 主循环 | ✅ 完成 | `daemon/vipd.py` |
| 1.6.2 | 配置文件加载 | ✅ 完成 | `daemon/vipd.py` |
| 1.6.3 | 日志系统 | ✅ 完成 | `daemon/vipd.py` |
| 1.6.4 | 审计日志 | ✅ 完成 | `daemon/audit.py` |
| 2.1.1 | 创建 plugin.yaml | ✅ 完成 | `hermes-plugin/plugin.yaml` |
| 2.1.2 | 创建 __init__.py | ✅ 完成 | `hermes-plugin/__init__.py` |
| 2.1.3 | 实现 register() 函数 | ✅ 完成 | `hermes-plugin/__init__.py` |
| 2.2.1 | 拦截 sudo 命令 | ✅ 完成 | `hermes-plugin/intercept.py` |
| 2.2.2 | 提交 VIP 并伪造错误 | ✅ 完成 | `hermes-plugin/intercept.py` |
| 2.2.3 | 重试时检测 pending | ✅ 完成 | `hermes-plugin/intercept.py` |
| 2.2.4 | 自动感知用户界面 | ✅ 完成 | `hermes-plugin/intercept.py` |
| 2.3.1 | 注册 /vip-pending 命令 | ✅ 完成 | `hermes-plugin/gateway_handler.py` |
| 2.3.2 | 注册 /vip-approve 命令 | ✅ 完成 | `hermes-plugin/gateway_handler.py` |
| 2.3.3 | 注册 /vip-deny 命令 | ✅ 完成 | `hermes-plugin/gateway_handler.py` |
| 2.3.4 | 绕过 LLM 机制 | ✅ 完成 | `gateway_handler.py` (依赖 Hermes 已有 bypass) |
| 2.4.1 | Kill 文件检测 | ✅ 完成 | `hermes-plugin/intercept.py` |
| 2.4.2 | Kill 文件创建脚本 | 🔴 待开始 | `examples/install-macos.sh` 已含 |
| 3.1.1 | launchd plist 模板 | ✅ 完成 | `examples/com.hermes.vipd.plist` |
| 3.1.2 | macOS 安装脚本 | ✅ 完成 | `examples/install-macos.sh` |
| 3.2.1 | systemd service 模板 | ✅ 完成 | `examples/hermes-vipd.service` |
| 3.2.2 | Linux 安装脚本 | ✅ 完成 | `examples/install-linux.sh` |
| 3.3.1 | 配置模板 | ✅ 完成 | `examples/config.yaml` |
| 3.3.2 | 安装引导 | 🔴 待开始 |
| 4.1 | README.md | ✅ 完成 | `README.md` |
| 4.2 | INSTALL.md | 🔴 待开始 | |
| 4.3 | CONTRIBUTING.md | ✅ 完成 | `CONTRIBUTING.md` |
| 4.4 | SECURITY.md | ✅ 完成 | `SECURITY.md` |
| 4.5 | GitHub 仓库初始化 | ✅ 完成 | `.git` |

## 待讨论的设计决策

见 `docs/DESIGN_DECISIONS.md`
