"""
Linux sandbox — bwrap implementation for Hermes VIP v8.0

Uses bubblewrap to create a mount-namespace isolated sandbox.
"""

import logging
import os
import shlex
import subprocess

logger = logging.getLogger("hermes-vip.sandbox.linux")


def _get_bwrap_path():
    try:
        r = subprocess.run(["which", "bwrap"], capture_output=True, text=True, timeout=5)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except Exception:
        pass
    return None


# ── bwrap base arguments ──
# System directories required for any command to run inside bwrap.

_BWRAP_BASE = [
    "--ro-bind", "/usr", "/usr",
    "--ro-bind", "/lib", "/lib",
    "--ro-bind", "/lib64", "/lib64",
    "--ro-bind", "/etc/passwd", "/etc/passwd",
    "--ro-bind", "/etc/group", "/etc/group",
    "--ro-bind", "/etc/resolv.conf", "/etc/resolv.conf",
    "--ro-bind", "/etc/ssl", "/etc/ssl",
    "--ro-bind", "/etc/ca-certificates", "/etc/ca-certificates",
    "--tmpfs", "/home",
    "--tmpfs", "/root",
    "--tmpfs", "/var",
    "--proc", "/proc",
    "--dev", "/dev",
    "--unshare-pid",
    "--cap-drop", "ALL",
    "--setenv", "SANDBOXED", "1",
    # /bin is a symlink to usr/bin on modern Ubuntu — recreate inside bwrap
    "--symlink", "usr/bin", "/bin",
    "--symlink", "usr/lib", "/lib",
    "--symlink", "usr/lib64", "/lib64",
]


def _build_linux_cmd(command: str, mounts: list, net_on: bool) -> str:
    """Wrap command in bwrap sandbox. Returns original if bwrap unavailable."""
    bwrap_path = _get_bwrap_path()
    if not bwrap_path:
        return command

    args = [bwrap_path] + _BWRAP_BASE
    if not net_on:
        args.append("--unshare-net")
    for flag, src, dst in mounts:
        args.extend([flag, src, dst])
    args.extend(["--", "/usr/bin/bash", "-c", command])
    return " ".join(shlex.quote(a) for a in args)
