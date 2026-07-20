"""
macOS sandbox — sandbox-exec implementation for Hermes VIP v8.0

Uses Apple's Seatbelt sandbox (sandbox-exec) for network/access control.
Architecture note: sandbox-exec works at syscall ACL level, not namespace level.
Unlike bwrap (Linux), files are VISIBLE but access is DENIED.
"""

import logging
import os
import re
import shlex
import shutil
import subprocess

logger = logging.getLogger("hermes-vip.sandbox.macos")


def _get_sandbox_exec_path():
    sb = shutil.which("sandbox-exec")
    return sb if sb else None


def _build_macos_cmd(command: str, mounts: list, net_on: bool, profile_path: str) -> str:
    """Wrap command in sandbox-exec. Returns original if sandbox-exec unavailable."""
    sb_path = _get_sandbox_exec_path()
    if not sb_path:
        return command

    # Use Apple's built-in no-internet profile for network isolation
    if not net_on:
        cmd_parts = [sb_path, "-n", "no-internet"]
    else:
        # When network is on, still use sandbox-exec with a custom profile
        # that restricts file access but allows network
        cmd_parts = [sb_path, "-n", "no-write"]

    # Run via bash -c to preserve shell behavior
    cmd_parts.extend(["/bin/bash", "-c", command])

    return " ".join(shlex.quote(a) for a in cmd_parts)
