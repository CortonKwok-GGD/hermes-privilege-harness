"""
macOS sandbox - _hermes user isolation for Hermes VIP v8.0

File isolation via hermes-run wrapper.
Network isolation via sandbox-exec (--no-net flag).
"""

import logging
import shlex

logger = logging.getLogger("hermes-vip.sandbox.macos")

_HERMES_RUN = "/usr/local/bin/hermes-run"


def _build_macos_cmd(command: str, net_on: bool) -> str:
    cmd = shlex.quote(command)
    if not net_on:
        return f"{_HERMES_RUN} --no-net {cmd}"
    return f"{_HERMES_RUN} {cmd}"


def apply_network(net_on: bool):
    pass


import os
import subprocess


def apply_mount_acls(mounts: list[tuple[str, str, str]]):
    for flag, path, _ in mounts:
        if not os.path.exists(path):
            continue
        writable = (flag == "--bind")
        parent = os.path.dirname(path)
        while parent and parent != "/":
            subprocess.run(["chmod", "-a", "user:_hermes", parent],
                           capture_output=True, timeout=5)
            subprocess.run(["chmod", "+a", f"user:_hermes allow list,search,file_inherit,directory_inherit", parent],
                           capture_output=True, timeout=5)
            parent = os.path.dirname(parent)

        perms = "read,write,append,add_subdirectory,file_inherit,directory_inherit" if writable else "read,file_inherit,directory_inherit"
        subprocess.run(["chmod", "-a", "user:_hermes", path],
                       capture_output=True, timeout=5)
        subprocess.run(["chmod", "+a", f"user:_hermes allow {perms}", path],
                       capture_output=True, timeout=5)
        logger.info("mount ACL: %s %s (writable=%s)", path, perms, writable)
