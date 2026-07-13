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
| Sandbox | `ssh admin@10.0.0.3` |
| PR fork (local) | `~/hermes-workspace/hermes-agent-pr` |
| PR upstream | https://github.com/NousResearch/hermes-agent/pull/63066 |
| Gitee mirror | https://gitee.com/cortonkwok/hermes-privilege-harness |

## Branches

| Branch | Guard | Use |
|--------|-------|-----|
| `main` | Active: blocks sudo, anti-loop, session state + stamp defense-in-depth | Daily use |
| `passive-vip` | Passive: stamp/verify only | Community PR |

## Security Architecture (v3.2)

```
LLM: vip_sudo("cmd")
  → check() → _stamp(cmd)              ← defense-in-depth: always stamp
  → return {action:"approve", rule_key:"vip:sudo"}
  → Hermes approval card → user choice: once / session / always / deny
  → handler: _verify(cmd)               ← REJECTED if no stamp
  → daemon → sudo → root
```

Session/always caching: handled entirely by Hermes core (VIP does NOT cache).
Once: VIP always requests approval — Hermes returns approved without persisting.
Session: Hermes writes in-memory session cache — subsequent calls skip card.
Always: Hermes writes command_allowlist to config.yaml (remove manually to revoke).
stamp/verify + terminal sudo interception + anti-loop = guard's defense-in-depth.

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
