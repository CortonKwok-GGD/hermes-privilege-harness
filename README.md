# Hermes VIP — Privilege Harness + Container Sandbox

> Terminal commands run in an isolated container VM. `vip_sudo` is the only way out.

## What it does

Hermes VIP gives an LLM two things:

1. **Container sandbox** — every terminal command runs inside an Apple Virtualization.framework VM (macOS) or Docker container (Linux). No approval needed for normal work.
2. **Privilege gateway** — one audited path to root: vip_sudo → approval card → daemon execution.

## Two versions

| | **main** (this Mac) | **passive-vip** (PR #63066) |
|}|
| Sandbox | Container VM isolation | None |
| vip_sudo | Stamp + verify + daemon | Stamp + verify + daemon |
| Tool routing | 3-path dispatch | Hermes native |
| Install | install-macos.sh | same installer |

## Quick Install

```bash
git clone https://github.com/CortonKwok-GGD/hermes-privilege-harness.git
cd hermes-privilege-harness
sudo bash examples/install-macos.sh
```

Requires Hermes Agent ≥ v0.18.0, macOS 26+ (for container sandbox).

## Architecture

```
LLM calls terminal("cmd")
  → Plugin wraps: /usr/local/bin/hermes-run cmd
    → container exec -i hermes-vm sh        ← Alpine VM
      → cmd runs in isolated VM

LLM calls vip_sudo("apt install x")
  → Plugin stamps command
  → Hermes shows approval card
  → User approves
  → Plugin sends to daemon via Unix socket
    → daemon runs: sudo apt install x        ← root on host
```

## Slash Commands

| Command | What it does |
|}|
| /vipsandbox on/off | Enable/disable container sandbox |
| /vipsandbox net on/off | Enable/disable network in sandbox |
| /vipsudo on/off | Enable/disable vip_sudo tool |
| /vipdaemon | Check if daemon is running |

## Key Paths

| Path | What |
|*|
| `/home/mac/hermes-workspace/apps/hermes-vip/` | Dev repo |
| /usr/local/bin/hermes-run | Container entry (deployed from container/macos/) |
| /usr/local/bin/hermes-vipd | Daemon entry |
| ~/.hermes/plugins/hermes-vip/config.yaml | Runtime config |
| /var/run/hermes-vip/request.sock | Daemon socket |

---

See [AGENTS.md](AGENTS.md) for the full AI agent guide, [WBS.md](WBS.md) for version history and lessons learned.
