# Hermes VIP — Root Privilege Gateway

> 🔐 **LLM 只有一个提权通道，永远经过你批准。**

Hermes VIP 是 Hermes Agent 的安全插件，解决一个核心问题：**LLM 在什么情况下、通过什么路径能获取 root 权限？**

答案：**只有 `vip_sudo` 一条路，而且每次都要你批准。**

## 为什么需要它

Hermes 原生的 sudo 方案是 `.env` 里存明文密码，LLM 调 `sudo` 时自动注入。密码在文件、环境变量、进程内存中到处飘。

VIP 的方案：**不需要密码。** 创建一个专用系统用户 (`_hermesvip`/`hermes-vip`)，它拥有 NOPASSWD sudo 但永远不被 LLM 直接访问。daemon 是这个用户唯一的代言人。

```
LLM → vip_sudo("command") → Hermes 原生审批卡片 → 你批准 → daemon 执行 → root
```

你的密码从头到尾不存在。

## 架构

```
┌──────────────────────────────────────────────────┐
│                    Hermes Agent                    │
│  ┌─────────┐    ┌──────────────────────────────┐ │
│  │ terminal │    │          vip_sudo             │ │
│  │ sudo xxx │    │  pre_tool_call → approve card │ │
│  │  → BLOCK │    │      → daemon → root         │ │
│  └─────────┘    └──────────┬───────────────────┘ │
└────────────────────────────┼──────────────────────┘
                             │ Unix socket
                    ┌────────▼──────────┐
                    │   VIP Daemon       │
                    │   (_hermesvip)     │
                    │   sudo <command>   │
                    └────────┬──────────┘
                             │
                        ┌────▼────┐
                        │  root   │
                        └─────────┘
```

## 安全模型

| 攻击路径 | 结果 |
|---------|:---:|
| LLM 调 `terminal("sudo xxx")` | ❌ 拦截 → "Use vip_sudo" |
| LLM 调 `terminal("sh -c 'sudo xxx'")` | ❌ LLM 拒绝 / 无密码 sudo → 失败 |
| 注入 Python 包调 `sudo` | ❌ 用户无 NOPASSWD sudo |
| 注入代码连 daemon socket | ❌ 不知道随机 session key |
| LLM 被注入后调 `vip_sudo("rm -rf /")` | ⚠️ 弹审批卡，你不批就不执行 |
| 同一命令连续失败 | 3次失败 → 120s 阻断 |

## 快速安装

### macOS

```bash
git clone https://github.com/yourname/hermes-vip.git
cd hermes-vip
sudo bash install.sh
```

### Linux

```bash
git clone https://github.com/yourname/hermes-vip.git
cd hermes-vip
sudo bash install.sh
```

安装后重启 Hermes Desktop。

## 使用

在 Hermes 中输入：

```
安装 htop
```

LLM 会自动调用 `vip_sudo`，弹出原生审批卡片。你用方向键选择 Approve，命令以 root 执行，结果返回。

也可以用 `vip_sudo` 直接：

```
用 vip_sudo 执行: rm -rf /Applications/SomeApp.app
```

## 要求

- Hermes Agent >= v0.18.0（原生审批卡片支持）
- macOS 或 Linux
- 安装时需要一次性输入 sudo 密码

## 许可

MIT
