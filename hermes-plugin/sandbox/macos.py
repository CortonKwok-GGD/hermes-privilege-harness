"""macOS sandbox - _hermes user isolation for Hermes VIP v8.1

Command wrapping: sudo -u _hermes (matches Linux implementation).
Network isolation: sandbox-exec (per-command, only when net_on=False).
"""

import logging
import shlex
import os
import subprocess

logger = logging.getLogger("hermes-vip.sandbox.macos")

_HERMES_USER = "_hermes"


def _build_macos_cmd(command: str, net_on: bool) -> str:
    quoted = shlex.quote(command)
    if not net_on:
        return "/usr/local/bin/hermes-run --no-net " + quoted
    return "/usr/local/bin/hermes-run " + quoted
def apply_network(net_on: bool):
    pass


def apply_mount_acls(mounts: list[tuple[str, str, str]]):
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
