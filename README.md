# Hermes Privilege Harness — `vip_sudo`

> 🔐 **v8.0: Tools run in sandbox by default. vip_sudo is the only way out.**

[English](#english) | [中文](#chinese)

---

## English

**v8.0 Source Switch:** All subprocess tools (terminal, execute_code) run inside a bwrap sandbox — no approval needed. File tools (read_file, write_file, etc.) are blocked and redirect to terminal equivalents. Unknown tools (browser, MCP, future tools) require vip_sudo approval. See [AGENTS.md](AGENTS.md) and [WBS.md](WBS.md) for the full architecture.

### Quick Install (Linux)

```bash
git clone https://github.com/CortonKwok-GGD/hermes-privilege-harness.git
cd hermes-privilege-harness
git checkout main
sudo bash examples/install-linux.sh
```

Requires Hermes Agent >= v0.18.0, Ubuntu 22.04+.

### Three Paths

```
Subprocess tools (terminal, execute_code)  → bwrap sandbox, transparent
In-process file tools (read/write/patch)   → block, use terminal instead
Data tools (todo, memory, skill, cronjob)  → pass through
Unknown tools (browser, MCP, new tools)    → block → use vip_sudo
Exit (vip_sudo)                            → approval card required
```

### Slash Commands

| Command | Effect |
|---------|--------|
| `/vipsandbox on|off` | Toggle sandbox (next chat) |
| `/vipsandbox net on|off` | Toggle network inside sandbox |
| `/vipsudo on|off` | Toggle VIP sudo interception |
| `/vipdaemon` | Show daemon status (read-only) |

### Key Files

| File | Purpose |
|------|---------|
| `hermes-plugin/guard.py` | Three-path tool dispatch + vip_sudo handler |
| `hermes-plugin/sandbox.py` | bwrap wrapping, config loading, env detection |
| `hermes-plugin/config.yaml` | Workspace mounts, sandbox/network toggle |
| `hermes-plugin/__init__.py` | Plugin registration + slash commands |
| `daemon/socket_server.py` | Privileged execution daemon (shared main/passive) |

---

## 中文

**v8.0 源头开关：** 所有子进程工具（terminal、execute_code）默认在 bwrap 沙箱内运行——无需审批。文件工具（read_file、write_file 等）被拦截，引导用 terminal 替代。未知工具（浏览器、MCP、未来工具）需要走 vip_sudo 审批。详细架构见 [AGENTS.md](AGENTS.md) 和 [WBS.md](WBS.md)。

### 快速安装（Linux）

```bash
git clone https://gitee.com/cortonkwok/hermes-privilege-harness.git
cd hermes-privilege-harness
git checkout main
sudo bash examples/install-linux.sh
```

需要 Hermes Agent >= v0.18.0，Ubuntu 22.04+。

### 三条路

```
子进程工具（terminal, execute_code）  → bwrap 沙箱，透明放行
进程内文件工具（read/write/patch）    → 拦截，用 terminal 替代
数据工具（todo, memory, skill...）   → 放行
未知工具（浏览器, MCP, 新工具）      → 拦截 → 走 vip_sudo
出口（vip_sudo）                     → 审批卡（唯一需批准）
```

### Slash 命令

| 命令 | 效果 |
|------|------|
| `/vipsandbox on|off` | 开关沙箱（下个对话生效） |
| `/vipsandbox net on|off` | 开关沙箱网络 |
| `/vipsudo on|off` | 开关 VIP sudo 拦截 |
| `/vipdaemon` | 查看 daemon 状态（只读） |

### 关键文件

| 文件 | 职责 |
|------|------|
| `hermes-plugin/guard.py` | 三条路工具分发 + vip_sudo handler |
| `hermes-plugin/sandbox.py` | bwrap 包装、配置加载、环境检测 |
| `hermes-plugin/config.yaml` | 工作区挂载、沙箱/网络开关 |
| `hermes-plugin/__init__.py` | 插件注册 + slash 命令 |
| `daemon/socket_server.py` | 提权执行 daemon（main/passive 共享） |

### 许可

MIT
