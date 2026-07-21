"""macOS sandbox — Apple container isolation for Hermes VIP v8.0+

Command wrapping:
  - Calls /usr/local/bin/hermes-run (deployed from container/macos/hermes-run.sh)
  - Uses Apple native container CLI for VM-level isolation
  - --no-net for network isolation (separate container with --network none)

Development discipline:
  - Source in repo: container/macos/hermes-run.sh
  - Deploy to production: dd if=container/macos/hermes-run.sh of=/usr/local/bin/hermes-run
  - Never edit /usr/local/bin/hermes-run directly
"""

import logging
import shlex
import os
import subprocess

logger = logging.getLogger("hermes-vip.sandbox.macos")


def _build_macos_cmd(command: str, net_on: bool) -> str:
    quoted = shlex.quote(command)
    if not net_on:
        return "/usr/local/bin/hermes-run --no-net " + quoted
    return "/usr/local/bin/hermes-run " + quoted


def apply_network(net_on: bool):
    pass  # Network isolation is per-container via --network none


def apply_mount_acls(mounts: list[tuple[str, str, str]]):
    """Legacy _hermes user ACL setup — kept for backward compat.
    Apple container sandbox uses -v mounts instead; ACLs are redundant
    when container/ provides the runtime."""
    for flag, path, _ in mounts:
        if not os.path.exists(path):
            continue
        writable = (flag == "--bind")
        parent = os.path.dirname(path)
        while parent and parent != "/":
            subprocess.run(["chmod", "-a", "user:_hermes", parent],
                           capture_output=True, timeout=5)
            subprocess.run(["chmod", "+a", "user:_hermes allow list,search,file_inherit,directory_inherit", parent],
                           capture_output=True, timeout=5)
            parent = os.path.dirname(parent)

        perms = "read,write,append,add_subdirectory,file_inherit,directory_inherit" if writable else "read,file_inherit,directory_inherit"
        subprocess.run(["chmod", "-a", "user:_hermes", path],
                       capture_output=True, timeout=5)
        subprocess.run(["chmod", "+a", "user:_hermes allow {perms}", path],
                       capture_output=True, timeout=5)
        logger.info("mount ACL: %s %s (writable=%s)", path, perms, writable)
