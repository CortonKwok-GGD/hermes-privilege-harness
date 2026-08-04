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
  enabled: true / false
  network: true / false
  container:                  # VM specs
    name: hermes-vm
    memory_mb: 2048
  proxy:
    socks5: socks5://192.168.64.1:1080  # Mac microsocks
  retry:
    intervals: [2, 60, 600]   # three-tier, no container restart
  mounts:                     # host_path → container_path
    - host_path: $HOME/.hermes/config.yaml          # ro
    - host_path: $HOME/.hermes/profiles             # ro
    - host_path: $HOME/hermes-workspace             # rw
    - host_path: $HOME/hermes-runtime/bin → /usr/local/bin   # rw
    - host_path: $HOME/hermes-runtime/data → /var/lib/hermes  # rw
    - host_path: $HOME/hermes-runtime/log → /var/log/hermes   # rw
vip_sudo:
  enabled: true / false
```

### Slash commands (main only)

| Command | Effect |
|---------|--------|
| `/vipsandbox on/off` | Toggle sandbox (next chat) |
| `/vipsandbox net on/off` | Toggle network in sandbox |
| `/vipsudo on/off` | Toggle vip_sudo tool |
| `/vipdaemon` | Check daemon via socket connectivity |

### Known issues (2026-07-25)

1. **container exec failures** — hermes-run uses three-tier retry (2s/60s/600s) without restarting the container; parallel tasks survive. ^C is forwarded into the container via trap+marker.
2. **container VM may not exist** — container-apiserver auto-starts, but VM must be created manually via `container run`
2. **config has 2 dev copies** — `hermes-plugin/config.yaml` is the canonical source; runtime version at `~/.hermes/plugins/hermes-vip/config.yaml` may diverge (provenance xattr prevents automated sync)
3. **macOS provenance xattr** — blocks writes to `~/.hermes/plugins/` even as root; use host terminal to edit
5. **macos.py `apply_mount_acls()`** — dead code; ACL blocked by com.apple.provenance on macOS 26+
6. **daemon startup on macOS = launchd plist, NOT watchdog** — `examples/com.hermes.vipd.plist` (RunAtLoad+KeepAlive, root runs mkdir/chown). The old `hermes-vipd-watchdog.sh` ran as the logged-in user, chown failed silently, daemon crashed on socket bind (2026-08-04)
7. **`trusted_user` must be TOP-LEVEL in /etc/hermes-vip/config.yaml** — vipd.py reads `config.get("trusted_user")`, NOT `daemon.trusted_user`. Value = the connecting Hermes user (e.g. mac/501), NOT the daemon's run user (_hermesvip). Missing -> only root(0) trusted (2026-08-04)
8. **macOS peercred: no `socket.SOL_LOCAL` constant** — `_get_peer_uid()` must use `getattr(socket, "SOL_LOCAL", 0)` / `getattr(socket, "LOCAL_PEERCRED", 1)`; direct reference raises AttributeError -> returns None -> rejects ALL connections (2026-08-04, fixed main 227167e / passive-vip 64f7883)
9. **one request per connection** — `_handle_request_client` closes after one request; tests must use two connections (stamp_init then sudo_execute), reuse -> BrokenPipe

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
- **Git push**: via SSH; Gitee direct, GitHub may need proxy. For HTTP proxy: `git config --global http.https://github.com.proxy http://10.0.0.5:8888`
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
| `container/macos/hermes-run.sh` | Container lifecycle + volume mounts + exec + signal cleanup | ~90 |
| `daemon/socket_server.py` | Unix socket server with UID verification | ~450 |
| `daemon/executor.py` | subprocess sudo executor | ~90 |
| `daemon/vipd.py` | Daemon main entry | ~150 |

---
See README.md for human overview, WBS.md for version history and lessons learned.
