# Hermes Privilege Harness — `vip_sudo`

> 🔐 **One path to root. Always user-approved.**
> 🔐 **LLM 只有一个提权通道，永远经过你批准。**

[English](#english) | [中文](#chinese)

---

## English

Hermes Privilege Harness is a security plugin for [Hermes Agent](https://github.com/NousResearch/hermes-agent). One question: **how does an LLM get root on your machine?** One answer: **`vip_sudo` — and you approve every time.**

### Why

Hermes' built-in sudo stores your password in plaintext (`SUDO_PASSWORD` in `.env`). That password lives everywhere — file, env, memory.

This plugin replaces passwords with a dedicated system user. `_hermesvip` has NOPASSWD sudo but the LLM can NEVER touch it directly. The VIP daemon is its sole voice.

```
LLM → vip_sudo("apt install htop") → native approval card → you approve → daemon → root
```

No password. Not in a file. Not in memory. Not anywhere.

### Architecture

```
┌───────────────────────────────────────────────┐
│                 Hermes Agent                    │
│  ┌──────────┐    ┌───────────────────────────┐ │
│  │ terminal │    │         vip_sudo           │ │
│  │ sudo xxx │    │  pre_tool_call→approve card│ │
│  │  → BLOCK │    │     → daemon → root       │ │
│  └──────────┘    └─────────┬─────────────────┘ │
└────────────────────────────┼────────────────────┘
                             │ Unix socket
                    ┌────────▼─────────┐
                    │   VIP Daemon      │
                    │   (_hermesvip)    │
                    │   sudo <command>  │
                    └────────┬──────────┘
                             │
                         ┌───▼───┐
                         │ root  │
                         └───────┘
```

### Security

| Attack | Result |
|--------|:---:|
| LLM: `terminal("sudo rm -rf /")` | ❌ Blocked |
| LLM hides sudo in `sh -c`, Python subprocess | ❌ User has no NOPASSWD |
| Injected package calls `sudo` | ❌ No NOPASSWD |
| Injected code hits daemon socket | ❌ Random session key |
| LLM: `vip_sudo("rm -rf /")` | ⚠️ Card — you decide |
| Same command fails repeatedly | 3× → 120s auto-block |

### Install

```bash
git clone https://github.com/CortonKwok-GGD/hermes-privilege-harness.git
cd hermes-privilege-harness
sudo bash install.sh
```

Restart Hermes Desktop. macOS & Linux.

### Requirements

- Hermes Agent >= v0.18.0

### License

MIT

---

## 中文

Hermes Privilege Harness 是 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 的安全插件。一个问题：**LLM 怎么拿到 root？** 一个答案：**`vip_sudo`，每次你批准。**

### 为什么需要

Hermes 原生 sudo 把密码明文存在 `.env` 里，文件、环境变量、内存到处飘。

这个插件把密码换成专用系统用户。`_hermesvip` 有 NOPASSWD sudo，但 LLM 永远不能直接碰到它。VIP daemon 是它唯一的代言人。

```
LLM → vip_sudo("apt install htop") → 原生审批卡片 → 你批准 → daemon → root
```

没有密码。不在文件里。不在内存里。不在任何地方。

### 架构

```
┌───────────────────────────────────────────────┐
│                 Hermes Agent                    │
│  ┌──────────┐    ┌───────────────────────────┐ │
│  │ terminal │    │         vip_sudo           │ │
│  │ sudo xxx │    │  pre_tool_call→审批卡片     │ │
│  │  → 拦截  │    │     → daemon → root       │ │
│  └──────────┘    └─────────┬─────────────────┘ │
└────────────────────────────┼────────────────────┘
                             │ Unix socket
                    ┌────────▼─────────┐
                    │   VIP Daemon      │
                    │   (_hermesvip)    │
                    │   sudo <command>  │
                    └────────┬──────────┘
                             │
                         ┌───▼───┐
                         │ root  │
                         └───────┘
```

### 安全模型

| 攻击路径 | 结果 |
|---------|:---:|
| LLM 调 `terminal("sudo rm -rf /")` | ❌ 拦截 |
| LLM 在 `sh -c`、Python subprocess 里藏 sudo | ❌ 用户无 NOPASSWD |
| 注入包调 `sudo` | ❌ 无 NOPASSWD |
| 注入代码连 daemon socket | ❌ 随机 session key |
| LLM 调 `vip_sudo("rm -rf /")` | ⚠️ 弹卡，你不批不执行 |
| 同一命令连续失败 | 3次 → 120s 阻断 |

### 安装

```bash
git clone https://gitee.com/cortonkwok/hermes-privilege-harness.git
cd hermes-privilege-harness
sudo bash install.sh
```

重启 Hermes Desktop。支持 macOS 和 Linux。

### 要求

- Hermes Agent >= v0.18.0

### 许可

MIT
