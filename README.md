# Hermes VIP — Verified Interface Process

Hermes 的 root 提权闸门。**LLM 看到不授权确认。**

## 架构

```
Hermes Plugin → request.sock → VIP Daemon (root)
                                      │
                               control.sock (root:600)
                                      │
                               Connector → 你的界面
                                      │
                              你回复 "/vip-approve a7f2"
                                      │
                              绕过 LLM 直达 daemon → 执行命令
```

## 快速开始

```bash
# macOS
curl -fsSL https://hermes-vip.dev/install-macos.sh | bash

# Linux
curl -fsSL https://hermes-vip.dev/install-linux.sh | bash
```

## 安全特性

- **LLM 看不到授权确认** — `/vip-approve` 绕过对话处理，由网关直接路由
- **模型不知道 VIP 存在** — sudo 命令返回标准错误"password required"
- **root 级密钥隔离** — bot token 存在 `/etc/hermes-vip/`，Hermes 读不了
- **一次性的 req_id** — 5 分钟 TTL，不可重放

## 连接器

| 连接器 | 需要额外配置 | 说明 |
|--------|------------|------|
| hermes_gateway | ❌ | 复用现有网关通道（默认） |
| CLI | ❌ | SSH 终端批准 |
| Telegram | 一个 bot token | 完全独立通道 |
| OS Dialog | ❌ | macOS/Linux 弹框 |

## 贡献

感谢所有连接器贡献者。详见 [CONTRIBUTING.md](CONTRIBUTING.md)。
