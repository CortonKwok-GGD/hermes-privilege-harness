# Hermes Privilege Harness (hermes-vip)

> 🔐 LLM only has one path to root: `vip_sudo`. Password-free, always user-approved.

## AI Agent Quick Start

When starting work on this project, immediately do:

1. **Load the skill**: `skill_view(name='hermes-vip')` — contains full dev workflows, anti-forget rules, pitfalls
2. **Check WBS**: `read_file('WBS.md')` — task history & current status
3. **Check which branch**: `main` (full guard) or `passive-vip` (community PR)

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
| This repo | `~/hermes-workspace/apps/hermes-vip` |
| Sandbox | `ssh admin@10.0.0.3` |
| PR fork (local) | `~/hermes-workspace/hermes-agent-pr` |
| PR upstream | https://github.com/NousResearch/hermes-agent/pull/63066 |
| Gitee mirror | https://gitee.com/cortonkwok/hermes-privilege-harness |

## Branches

| Branch | Guard | Use |
|--------|-------|-----|
| `main` | Active: blocks sudo, anti-loop, session state | Daily use |
| `passive-vip` | Passive: stamp/verify only | Community PR |

## Dev Rules

- **Never `sudo` in terminal** — VIP guard blocks it. User runs manually or via vip_sudo
- **Don't install tesseract** — macOS has native Vision OCR
- **Sandbox PATH**: `/home/admin/.hermes/bin/hermes` (git), not pip version
- **CN Desktop paths differ** from standard paths
- **Sandbox admin NOPASSWD** must stay (eds-sudoers, Alibaba Wuying dependency)
- **Sandbox Wuying GUI** needs `libqt5*` + `libgoogle-glog`
- **Plugin install**: `echo n | hermes plugins enable hermes-vip` (suppress override prompt)
