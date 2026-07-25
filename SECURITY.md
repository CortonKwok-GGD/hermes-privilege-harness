# Security Model

## Layers

| Layer | Mechanism | What it protects |
|-------|-----------|-----------------|
| Container VM | Apple Virtualization.framework (macOS) | LLM cannot see host filesystem, processes, or SSH keys |
| Volume mounts | config.yaml sandbox.mounts whitelist | Only workspace + specific config files visible |
| Network isolation | --no-net container flag | LLM cannot reach external network when disabled |
| Stamp verification | SHA-256 hash + 15s TTL in guard.py | vip_sudo handler refuses unstamped commands |
| Blocklist | YAML rules in /usr/local/etc/hermes-vip/blocklist.yaml | Even approved commands checked for dangerous patterns |
| Daemon isolation | _hermesvip user + NOPASSWD sudoers | LLM cannot access daemon socket directly without going through guard |
| Unix socket UID check | socket_server.py peer credential verification | Only trusted UIDs can submit to control socket |

## Threat Model

| Attack | Blocked by |
|--------|-----------|
| LLM reads ~/.ssh/ | Container VM isolation (path not mounted) |
| LLM calls sudo directly | guard.py blocks terminal sudo, redirects to vip_sudo |
| LLM bypasses approval card | Stamp verification — handler rejects unstamped commands |
| LLM executes dangerous approved command | Blocklist check in guard.vip_sudo() |
| LLM writes to ~/.hermes/plugins/ | macOS provenance xattr + container volume isolation |

## Daemon Architecture

- Runs as _hermesvip user with NOPASSWD sudo
- Managed by Login Items + watchdog script (auto-restart on crash)
- Two Unix sockets: request.sock (plugin→daemon) and control.sock (approval queries)
- All executions logged via audit.py

## Known Limitations

- macOS provenance xattr prevents automated config sync to ~/.hermes/plugins/
- Container VM needs manual creation if deleted (hermes-run does not auto-create)
- Desktop auto-update wipes VIP patches in ~/.hermes/hermes-agent/
