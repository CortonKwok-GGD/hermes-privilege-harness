# Hermes VIP — 安全隔离方案 v4

> 2026-07-16 | 沙箱: 10.0.0.3 (Ubuntu 22.04, GNOME Desktop)
> 下次继续: 阅读本文末尾「现状与阻塞点」

## 架构：容器 dashboard + CLI wrapper

### 核心原则

**全部文件在宿主机，用户全权管理。容器只做 LLM 沙箱，不拥有状态。**

### 当前可用

| 入口 | 怎么用 | 身份 | 状态 |
|:---|:---|:---|:--:|
| CLI | `hermes chat` | `_hermes`(996) | ✅ 验证通过 |
| Admin | 直接编辑 host 文件 | admin(1000) | ✅ |

### 架构图

```
宿主机 (admin)                         容器 (_hermes UID 996)
─────────                             ─────────
~/.hermes/
  ├─ skills/ ───────── :rw ─────→   skills/
  ├─ memory/ ───────── :rw ─────→   memory/
  └─ plugins/ ──────── :rw ─────→   plugins/

~/hermes-container/
  ├─ config.yaml ───── :ro ─────→   config.yaml (防注入)
  ├─ state/
  │   ├─ state.db ──── :rw ─────→   state.db (持久化)
  │   └─ sessions/ ─── :rw ─────→   sessions/
  └─ compose.env

~/hermes-workspace/ ─── :rw ─────→   workspace/

~/.hermes/hermes-agent/
  apps/desktop/dist/ ── :ro ─────→   /web-dist (预编译 UI)

/var/run/hermes-vip/ ── :ro ─────→   VIP daemon socket

.env ────────────────── env_file ─→  (Docker 注入，不进容器文件系统)

CLI ──→ ~/.hermes/bin/hermes (wrapper) ──→ docker exec hermes-agent
```

### CLI Wrapper

`~/.hermes/bin/hermes` — 所有 CLI 命令直通容器：

```bash
#!/bin/bash
if [ -t 0 ]; then
    exec docker exec -it hermes-agent hermes "$@"
else
    exec docker exec -i hermes-agent hermes "$@"
fi
```

原 host hermes 未改动（venv 已恢复原状），wrapper 在 PATH 中优先级更高。

### 权限策略

| 路径 | 宿主机 | 容器 mount |
|:---|:---|:--:|
| config.yaml (hermes-container/) | admin:admin 644 | :ro |
| skills/ | chmod 777 | :rw |
| memory/ | chmod 777 | :rw |
| state.db (hermes-container/state/) | chmod 666 | :rw |
| sessions/ (hermes-container/state/) | chmod 777 | :rw |
| workspace/ | admin:admin 755 | :rw |
| web-dist (desktop/dist/) | admin:admin 755 | :ro |
| .env | admin:admin 600 → Docker env_file 注入 | N/A |

### 已验证 (10.0.0.3) — 2026-07-16 v4

| 验证项 | 结果 |
|:---|:--:|
| 容器 dashboard (--skip-build + dist) | ✅ |
| Web UI served (HTTP 200) | ✅ |
| Session token 嵌入 HTML | ✅ |
| WebSocket gateway.ready | ✅ |
| CLI `hermes chat` → `_hermes` | ✅ |
| `hermes --version` → 容器 v0.18.2 | ✅ |
| `/etc/shadow` 不可读 | ✅ |
| `~/.ssh` 不可见 | ✅ |
| `sudo` 未安装 | ✅ |
| config.yaml :ro (write 被拒绝) | ✅ |
| state.db :rw 持久化到宿主机 | ✅ |
| DEEPSEEK_API_KEY env_file 注入 | ✅ |
| VIP socket 目录挂载 | ✅ |

### 已验证不可行

| 尝试 | 原因 |
|:---|:---|
| 浏览器直接访问 `http://127.0.0.1:9119` | 预编译 dist 是 Electron 版，依赖 `Desktop IPC bridge`，纯浏览器报错 |
| `hermes serve` 容器模式 | headless 模式不提供 web UI（`web UI disabled`） |
| `hermes serve` 绑 `0.0.0.0` | Hermes 拒绝：需要 auth provider |

## 现状与阻塞点

### 已解决 ✅

- **CLI 隔离**：wrapper → `docker exec` → `_hermes`。可用。
- **容器 dashboard**：`hermes dashboard --skip-build` + 挂载 host dist。WebSocket、session token 全通。
- **.env 跨 UID**：Docker `env_file` 注入，不挂载文件。
- **state.db 持久化**：启动前 `python3 -c "import sqlite3; sqlite3.connect(path).close()"` 预创建合法 SQLite。
- **VIP socket**：挂目录 `/var/run/hermes-vip`，不是单文件。

### 阻塞 ❌ — Desktop 隔离

Desktop（沙箱 GNOME Electron 应用）的 LLM 目前以 admin(1000) 执行，原因是：

1. **Desktop 启动协议**：Desktop 内部 spawn `python -m hermes_cli.main dashboard --no-open`，然后读 stdout 取端口、GET / 取 HTML、提取 `window.__HERMES_SESSION_TOKEN__`、连接 WebSocket
2. **容器 `hermes dashboard` 满足全部协议**：端口输出、HTML serve、session token 嵌入、WebSocket——全部通过
3. **但是**：如果让 Desktop 正常 spawn，它启动的是 host 本地的 dashboard（admin），不走容器
4. **如果用 wrapper 拦截** Desktop spawn 并输出容器端口 `:9119`，Desktop 能连上容器 dashboard，但 **之前测试 Desktop 报 "could not connect to Hermes gateway"**

需要排查：Desktop 连接容器 dashboard 失败的原因。可能原因：
- Desktop 做了额外的 health check 或进程监控（检查 spawn 的子进程是否存活）
- Desktop 的 gateway URL 构建逻辑有特殊处理
- Token 匹配问题（Desktop 生成 token 传给子进程，但容器用固定 token）

### 两条出路

**路 1：Desktop 连容器 dashboard（wrapper 方案）**
- 重新部署 python wrapper（拦截 `hermes_cli.main dashboard` → 输出 `:9119`）
- 排查 Desktop 连接失败根因
- 优点：不改容器，不改 Desktop
- 缺点：已尝试一次，未定位根因

**路 2：自建浏览器兼容 web UI**
- 写一个简单 HTML/JS 页面，通过 WebSocket 连容器 dashboard
- 不依赖 Electron IPC
- 优点：彻底绕过 Desktop 依赖
- 缺点：需开发

### 容器代码

```
~/hermes-container/               # 沙箱部署目录
├── Dockerfile                    # Ubuntu 22.04 + pip hermes-agent
├── docker-compose.yml            # dashboard + web-dist mount
├── config.yaml                   # DeepSeek API
├── state/                        # 持久化（state.db + sessions/）
└── hermes-container.sh

~/hermes-workspace/hermes-container/  # 本地开发目录
├── docker-compose.yml
├── Dockerfile
├── config-sandbox.yaml
└── hermes-serve-proxy.sh         # Mac SSH 隧道 (备用)
```

沙箱部署: `admin@10.0.0.3:~/hermes-container/`

### 踩坑记录

1. **`cat > symlink` 覆写目标文件** — 写 wrapper 前必须 `rm -f`。本 session 中覆写了 uv python3.11，用 `ln -sf /usr/bin/python3.11` 恢复。
2. **Docker bind mount 空路径 → 自动创建目录** — state.db 必须预创建合法 SQLite 文件。
3. **`docker exec -i` 无 TTY** — 交互式 CLI 需 `-it`，用 `[ -t 0 ]` 检测。
4. **Desktop spawn 用 `python -m hermes_cli.main` 不经过 `hermes` 脚本** — 单 wrap `hermes` 不够，需同时 wrap `python`。
5. **Desktop 把 `serve` 转成 `dashboard --no-open`** — wrapper 需拦截 `dashboard` 而非 `serve`。
6. **容器 serve 绑 `0.0.0.0` 被拒** — Hermes 要求 auth provider。
7. **`.env` 跨 UID :ro 挂载 → PermissionError** — 容器 `_hermes`(996) 不是 host admin(1000)，600 权限 other 位不可读。
8. **预编译 web dist 是 Electron 版** — 纯浏览器访问报 "Desktop IPC bridge is unavailable"。

### 历史方案

- **v3 统一入口 wrapper** — 尝试通过 wrapper 拦截 Desktop spawn → 发现 Desktop 用 `dashboard --no-open`，需要 web UI + session token
- **v7.0 `_hermes` 用户隔离** — ACL + 跳板脚本。阻塞于 ACL 重置、IME 失效、升级覆盖配置。被容器方案替代。
- **v4.0 网关隔离** — 远程 gateway 连接。阻塞于 web UI 构建需要 npm。

详见 `hermes-vip` skill references/。
