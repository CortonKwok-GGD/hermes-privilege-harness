# Hermes Privilege Harness (hermes-vip)

> 🔐 v8.0: Tools run in sandbox by default. vip_sudo is the only way out.

## AI Agent Quick Start

When starting work on this project, immediately do:

1. **Load the skill**: `skill_view(name='hermes-vip')`
2. **Check WBS**: `read_file('WBS.md')`
3. **Check sandbox state**: `/sandbox` and `/vipsudo` in current chat

## CRITICAL: Environment Rules

### GitHub Operations — Proxy Required
```
ALL_PROXY=socks5://10.0.0.5:8888 git <command>
```

### Image OCR — Native Tool Only (no tesseract)
```
swift ~/hermes-workspace/sanzi/scripts/ocr.swift <image_path>
```

## Key Paths

| What | Path |
|------|------|
| Git repo | `~/hermes-workspace/apps/hermes-vip/` |
| Daemon install | `/usr/local/lib/hermes-vip/` |
| Daemon entry | `/usr/local/bin/hermes-vipd` |
| Plugin install | `~/.hermes/plugins/hermes-vip/` |
| VIP config | `~/.hermes/plugins/hermes-vip/config.yaml` |
| Blocklist | `/usr/local/etc/hermes-vip/blocklist.yaml` |
| Sandbox | `ssh admin@10.0.0.3` |

## v8.0 Architecture — Three Paths

```
所有工具
  ├── 子进程（terminal, execute_code）
  │   → bwrap 包装，透明放行（无审批）
  │
  ├── 进程内函数（read_file, write_file, patch, search_files, vision_analyze）
  │   → block → "Use terminal: cat/echo/sed/grep..."
  │
  ├── 数据工具（todo, memory, skill_*, cronjob, project_*, ...）
  │   → 放行（不碰文件系统）
  │
  ├── 未知工具（browser_*, web_search, MCP, 未来工具）
  │   → block → "Use vip_sudo"
  │
  └── 出口（vip_sudo）
      → 审批卡（唯一需要用户批准的工具）
```

分类标准不是工具名，是**执行形态**：能否包进 bwrap（子进程）vs 进程内函数。没有白名单补偿。

### System Prompt (state-aware)

```
Sandbox ON, vip_sudo ON:  "In sandbox. Terminal — no approval. vip_sudo — only approval needed."
Sandbox ON, vip_sudo OFF: "In sandbox. Terminal — no approval. vip_sudo disabled — ask user."
Sandbox OFF:              "Sandbox off. vip_sudo available (or system sudo if disabled)."
```

### Slash Commands

| Command | Effect |
|:---|:---|
| `/sandbox on|off` | Toggle sandbox (persisted to config.yaml) |
| `/sandbox net on|off` | Toggle network inside sandbox |
| `/sandbox` | Show current sandbox + network status |
| `/vipsudo on|off` | Toggle vip_sudo (persisted to config.yaml) |
| `/vipsudo` | Show current vip_sudo status |
| `/vipdaemon` | Show VIP daemon status (read-only) |

## Security Architecture (v8.0)

```
LLM: terminal("sudo xxx")
  → guard.check()
  → sudo in command? → block → "Use vip_sudo"

LLM: read_file("~/.ssh/key")
  → guard.check()
  → in _FILE_TOOL_HINTS? → block → "Use terminal: cat <path>"

LLM: browser_navigate(url)
  → guard.check()
  → unknown tool? → block → "Use vip_sudo"

LLM: terminal("cat workspace/file")
  → guard.check()
  → subprocess tool? → wrap in bwrap → transparent pass ✅

LLM: vip_sudo("apt install nginx")
  → guard.check()
  → _stamp(cmd)
  → approve card → user approves
  → handler: _verify(cmd) → REJECTED if no stamp
  → _check_blocklist(cmd) → YAML + fallback
  → daemon → sudo → root
```

No mount lists, no whitelists, no per-tool compensation. Three clear categories.

### v7.x legacy (Docker container, _hermes user, triple wrapper)

Superseded by v8.0 bwrap approach. See WBS.md for history.

## Dev Rules

- **Never `sudo` in terminal** — VIP guard blocks it. Use `vip_sudo` or run manually
- **Don't install tesseract** — macOS has native Vision OCR
- **Develop in `~/hermes-workspace/apps/hermes-vip/`**, deploy to sandbox first
- **Sandbox**: `ssh admin@10.0.0.3`
- **Sandbox Hermes**: `export PATH="$HOME/.hermes/bin:$PATH"`
- **Plugin install**: `hermes plugins enable hermes-vip` (say no to tool override)
- **VIP config**: `config.yaml` in plugin dir — editable, takes effect on next chat
- **Daemon Python**: system `/usr/bin/python3` (3.9), stdlib only
- **Socket dir**: `SOCKET_DIR_MODE = 0o750` (admin in hermes-vip group)

## 🥇 Three Sacred Dev Rules (ALL projects)

### 1. 🚫 生产勿碰
Develop in sandbox first. User decides when to deploy to Mac production.

### 2. 🧪 沙箱先测
Everything that affects system state must be tested on 10.0.0.3 first.

### 3. ⚔️ 沙箱攻击模拟
Every test round includes attacker perspective: can LLM read SSH keys? Can it bypass bwrap? Can it write outside workspace?

---

## macOS vs Linux 差异

| 方面 | Linux (10.0.0.3) | macOS (本地) |
|:---|:---|:---|
| 沙箱实现 | bwrap (bubblewrap) | sandbox-exec (Phase 2)，当前无沙箱 (Phase 1) |
| 沙箱状态 | ✅ 完整 bwrap 隔离 | ⬜ Phase 1 仅 vip_sudo，Phase 2 加 sandbox-exec |
| daemon 管理 | systemd | Login Items + watchdog |
| socket 路径 | `/run/hermes-vip/request.sock` | `/var/run/hermes-vip/request.sock` |
| 安装脚本 | `examples/install-linux.sh` | `examples/install-macos.sh` |
| 验证沙箱 | `ssh admin@10.0.0.3` | 本地 Desktop 开新对话 |
| workspace 权限 | `admin:admin`（自然匹配） | `hermes-shared` 共享组（Docker _hermes 兼容） |

### 开发规则

- **Linux 上开发沙箱功能**：`sandbox.py` 改动先部署到 10.0.0.3 测试
- **macOS 上开发非沙箱功能**：guard 逻辑、slash command、config 读写可在本地直接测
- **跨平台改动**：同时部署沙箱验证 Linux + 本地验证 macOS 不崩
- **不要在一个平台上写死另一个平台的逻辑**：用 `sys.platform` 或 `shutil.which("bwrap")` 做运行时检测


## v8.1 工具分类更新

子进程 → hermes-run 包装（terminal, execute_code）
放行白名单 → cronjob 移除（网络绕过风险）
未知工具 → block → Use vip_sudo

## v8.2 架构更新

### 沙箱实现

| 平台 | 实现 | 隔离机制 |
|:---|:---|:---|
| Linux (10.0.0.3) | hermes-run to docker exec hermes-vm | 容器卷挂载白名单 + --network none/bridge |
| macOS (本地) | hermes-run to sudo -u _hermes bash -c | _hermes 用户隔离 + sandbox-exec |
### Linux Docker 沙箱明细
- 镜像: hermes-vm (Alpine 3.20 + python3/git/curl/gcc/bash)
- 容器: 常驻 hermes-vm / hermes-vm-no-net, --user 1000:1000
- 挂载: config.yaml sandbox.mounts 驱动 -v 参数
- 网络: sandbox.network true/false 控制 --network bridge/none
- 白名单外路径完全不可见
### macOS 审批
- Tirith: security.tirith_enabled: false
- 危险命令检测: Desktop approvals.mode: off 跳过
- VIP guard: 仍拦截 sudo 提权 + 包装 hermes-run
### 开发验证顺序
1. Linux 沙箱 (10.0.0.3) 先验证
2. macOS 本地 直接测
3. 生产部署 用户确认
