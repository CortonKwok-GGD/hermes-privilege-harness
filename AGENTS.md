# Hermes Privilege Harness (hermes-vip)

> 🔐 LLM only has one path to root: `vip_sudo`. Password-free, always user-approved.

## AI Agent Quick Start

When starting work on this project, immediately do:

1. **Load the skill**: `skill_view(name='hermes-vip')` — contains full dev workflows, anti-forget rules, pitfalls
2. **Check WBS**: `read_file('WBS.md')` — task history & current status
3. **Check which branch**: `main` (full guard + stamp defense-in-depth) or `passive-vip` (community PR)

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
| Watchdog | `~/.hermes/scripts/hermes-vipd-watchdog.sh` |
| Login Item | `~/.hermes/apps/hermes-vipd-watchdog.app` (AppleScript wrapper) |
| Blocklist | `/usr/local/etc/hermes-vip/blocklist.yaml` (16 rules, fail-closed) |
| Sandbox | `ssh admin@10.0.0.3` |
| PR fork (local) | `~/hermes-workspace/hermes-agent-pr` |
| PR upstream | https://github.com/NousResearch/hermes-agent/pull/63066 |
| Gitee mirror | https://gitee.com/cortonkwok/hermes-privilege-harness |

## Branches

两个分支代表 **两种不同的信任模型**，不是代码分支的区别。

| | `main` (自用) | `passive-vip` (社区 PR) |
|---|---|---|
| **仓库** | `hermes-privilege-harness` | `hermes-agent/pull/63066` |
| **入口点** | `contrib/privilege-harness/` | 同，从 main 复制但去掉了自用残留 |
| **信任谁** | 不信任 LLM，也不完全信任 Hermes 框架 | 信任 Hermes 原生审批系统 |
| **防御层数** | 3 层：plugin 拦截 → blocklist → daemon stamp | 1.5 层：Hermes 审批 + daemon stamp |
| **代码哲学** | "我能自己做的就自己做" | "只做 Hermes 做不了的事" |

### 功能差异

| 功能 | `main` | `passive-vip` | 说明 |
|------|:--:|:--:|------|
| terminal sudo 拦截 | ✅ | ❌ | main 主动拦截；passive 信任 Hermes 原生 |
| blocklist (33 规则) | ✅ | ❌ | `useradd`、`rm -rf /` 等危险命令 |
| gateway 审批通知 | ✅ | ❌ | 微信/Telegram 推送审批卡片 |
| git push 保护 | ✅ | ❌ | DANGEROUS_PATTERNS 注入 |
| 防循环 | ✅ | ❌ | 重复失败自动封禁 |
| daemon stamp 防御 | ✅ | ✅ | **共享层** |
| vip_sudo 审批卡 | ✅ | ✅ | **共享层** |

### 为什么不能合并

- **main → 上游**：会被拒。依赖内部 API（`tools.approval` monkey-patch）、gateway connector、自定义 blocklist。reviewer 不会接受。
- **passive → 自用**：不够用。没有 blocklist 的话 LLM 能跑 `useradd`；没有 gateway 的话手机上收不到审批；没有防循环的话会死循环。
- **passive 作为 base + main 的额外功能作为可选配置**：理论上可行，但 blocklist 注入和 gateway handler 这些依赖对 Hermes 内部的 monkey-patch，不适合放进社区仓库。

### 共享组件：daemon

两个分支的 daemon（`daemon/socket_server.py`）共享 stamp defense-in-depth。daemon 不关心也不该关心是谁在调它——plugin 还是 Hermes 原生。它只管验 HMAC stamp。

```
main:      terminal sudo → guard 拦截 → vip_sudo → 审批卡 → daemon
passive:   Hermes 检测 → vip_sudo → 审批卡 → daemon
                                          ↑
                                    stamp defense-in-depth
                                    两个分支都需要
```

同步纪律：daemon 的任何安全改进必须在两边同步，不允许只改一边。

## Security Architecture (v3.3)

```
LLM: terminal("sudo xxx")
  → _has_privilege_escalation() → SSH远程? 放行 : 匹配5模式? block : pass
  → block → "Use vip_sudo"

LLM: vip_sudo("cmd")
  → check() → _stamp(cmd)              ← defense-in-depth: always stamp
  → return {action:"approve", rule_key:"vip:sudo"}
  → _check_blocklist(cmd)               ← YAML + fallback (fail-closed)
  → Hermes approval card → user choice: once / session / always / deny
  → handler: _verify(cmd)               ← REJECTED if no stamp
  → daemon → sudo → root
```

Session/always caching: handled entirely by Hermes core (VIP does NOT cache).
Once: VIP always requests approval — Hermes returns approved without persisting.
Session: Hermes writes in-memory session cache — subsequent calls skip card.
Always: Hermes writes command_allowlist to config.yaml (remove manually to revoke).
Blocklist: /usr/local/etc/hermes-vip/blocklist.yaml (16 rules, fail-closed fallback).
stamp/verify + terminal sudo interception + blocklist + anti-loop = guard's defense-in-depth.

## Dev Rules

- **Never `sudo` in terminal** — VIP guard blocks it. User runs manually or via vip_sudo
- **Don't install tesseract** — macOS has native Vision OCR
- **Install from repo root**: `cd examples && sudo bash install-macos.sh`
- **Develop in `~/hermes-workspace/apps/hermes-vip/`**, deploy to `/usr/local/`
- **Sandbox PATH**: `/home/admin/.hermes/bin/hermes` (git), not pip version
- **Sandbox admin NOPASSWD** must stay (eds-sudoers, Alibaba Wuying dependency)
- **Sandbox Wuying GUI** needs `libqt5*` + `libgoogle-glog`
- **Plugin install**: `echo n | hermes plugins enable hermes-vip` (suppress override prompt)
- **Socket permission**: 660 `_hermesvip:daemon` — mac user must be in daemon group
- **Daemon Python**: system `/usr/bin/python3` (3.9), stdlib only

## 🥇 Three Sacred Dev Rules (ALL projects)

These apply to every project in this workspace — not just VIP.

### 1. 🚫 生产勿碰
Develop and audit in sandbox or /dev directory. Never operate on production environment unless a problem has actually occurred. User decides when to sync to production.

### 2. 🧪 沙箱先测
Every command that affects system state must be tested in sandbox first. User provides results — user does not test on production themselves.

### 3. ⚔️ 沙箱攻击模拟
Every test round includes an attacker perspective: unauthorized UID, wrong script_path, direct file reads, ACL bypass attempts. Verify that all defense layers hold. Use a non-root tester user (not proot's uid=0).
