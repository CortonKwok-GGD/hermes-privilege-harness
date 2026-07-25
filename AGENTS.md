# Hermes VIP — AI Agent Guide

> v8.0: terminal commands run in container sandbox. vip_sudo is the only way out.

## Quick Start (for a new agent session)

1. Read this file — it''s the project map
2. Check `/vipsandbox` and `/vipsudo` in chat for current state
3. For version history and known issues, see WBS.md

## What This Project Is

Three subsystems merged into one repo, covering two branches:

```
                    DAEMON (shared by both branches)
                         |
            ┌────────────┼────────────┐
            ▼                         ▼
      main branch              passive-vip branch
      (full sandbox)           (privilege-only, PR #63066)
```

| Subsystem | Dir | What it does | In passive-vip? |
|-----------|-----|-------------|:---:|
| **Daemon** | `daemon/` | Unix socket server that runs `sudo <cmd>` as `_hermesvip` | ✅ shared |
| **Plugin** | `hermes-plugin/` | Tool routing, VIP guard, sandbox wrapping, slash commands | ✅ (simplified) |
| **Container** | `container/` | `hermes-run` script + Dockerfiles for VM-level isolation | ❌ main only |

## Architecture (main branch — what runs on this Mac)

```
LLM calls tool
  → guard.check() — three-path routing
    ├─ terminal → sandbox.build_sandbox_cmd() → hermes-run → container exec
    ├─ vip_sudo → stamp → approval card → daemon socket → executor sudo
    └─ data tools (memory, skill_*, etc.) → pass through
```

### Key paths (host → deployed)

| Dev repo | Deployed to |
|----------|------------|
| `container/macos/hermes-run.sh` | `/usr/local/bin/hermes-run` (via `dd`) |
| `hermes-plugin/*` | `~/.hermes/plugins/hermes-vip/` (via install script) |
| `daemon/*` | `/usr/local/lib/hermes-vip/` (via install script) |
| `daemon/vipd.py` | `/usr/local/bin/hermes-vipd` (wrapper) |

### Config (single source of truth)

`hermes-plugin/config.yaml` → deployed to `~/.hermes/plugins/hermes-vip/config.yaml`

```yaml
sandbox:
  enabled: true / false       # Container sandbox on/off
  network: true / false       # Network inside sandbox
  mounts:                     # Paths mounted into container VM
    - path: $HOME/hermes-workspace     # rw
    - path: $HOME/.hermes/plugins/hermes-vip/config.yaml  # ro (LLM self-discovery)
    - path: $HOME/.hermes/config.yaml  # ro
    - path: $HOME/.hermes/profiles     # ro
vip_sudo:
  enabled: true / false       # vip_sudo tool on/off
```

### Slash commands (main only)

| Command | Effect |
|---------|--------|
| `/vipsandbox on/off` | Toggle sandbox (next chat) |
| `/vipsandbox net on/off` | Toggle network in sandbox |
| `/vipsudo on/off` | Toggle vip_sudo tool |
| `/vipdaemon` | Check daemon via socket connectivity |

### Known issues (2026-07-25)

1. **container not running** — container-apiserver down, hermes-run will auto-start system but container VM may not exist
2. **config has 2 dev copies** — `hermes-plugin/config.yaml` is the canonical source; runtime version at `~/.hermes/plugins/hermes-vip/config.yaml` may diverge (provenance xattr prevents automated sync)
3. **macOS provenance xattr** — blocks writes to `~/.hermes/plugins/` even as root; use host terminal to edit
4. **`_handle_vipdaemon`** — previously used launchctl (broken for watchdog-managed daemon); now uses Unix socket ping
5. **macos.py `apply_mount_acls()`** — dead code; ACL blocked by com.apple.provenance on macOS 26+

## Two Branches

### main — Full sandbox (this Mac)
- **Plugin**: 3-path routing, sandbox dispatch, slash commands, system prompt injection
- **Container**: `hermes-run` → Apple container VM (macOS) or Docker (Linux)
- **Philosophy**: VIP controls everything — sandbox, routing, approval

### passive-vip — Privilege-only (PR #63066)
- **Plugin**: Only vip_sudo stamp/verify → daemon execution
- **No sandbox, no container, no routing**
- **Philosophy**: Hermes handles approval + danger detection; VIP just executes
- **guard.py**: ~200 lines (vs main ~370 lines)
- **Daemon**: identical to main branch

## Dev Rules

- **Dev in repo, deploy via dd/install script** — never edit deployed files directly
- **macOS 26 SIP**: `/usr/local/bin/` is write-protected — use `dd if=src of=dst`
- **Git push**: requires proxy (`ALL_PROXY=socks5://10.0.0.5:8888`) + workspace SSH key
- **Dual Hermes install**: workspace (`~/hermes-workspace/hermes-agent/`) vs runtime (`~/.hermes/hermes-agent/`) — Desktop auto-update wipes patches
- **Sandbox testing**: Linux sandbox at `ssh admin@10.0.0.3`; macOS testing directly on Desktop

## Key Files Reference

| File | Purpose | Lines |
|------|---------|-------|
| `hermes-plugin/guard.py` | Three-path tool dispatch + vip_sudo handler | ~370 |
| `hermes-plugin/__init__.py` | Plugin registration + hooks + slash commands | ~200 |
| `hermes-plugin/sandbox/__init__.py` | Platform dispatch + config management | ~180 |
| `hermes-plugin/sandbox/macos.py` | Wrap terminal → hermes-run (Apple container) | ~50 |
| `hermes-plugin/sandbox/linux.py` | Wrap terminal → hermes-run (Docker) | ~60 |
| `container/macos/hermes-run.sh` | Container lifecycle + volume mounts + exec | ~55 |
| `daemon/socket_server.py` | Unix socket server with UID verification | ~450 |
| `daemon/executor.py` | subprocess sudo executor | ~90 |
| `daemon/vipd.py` | Daemon main entry | ~150 |

---
See README.md for human overview, WBS.md for version history and lessons learned.
