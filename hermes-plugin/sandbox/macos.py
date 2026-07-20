"""
macOS sandbox — _hermes user isolation for Hermes VIP v8.0

File isolation via dedicated _hermes user + ACL.
Network isolation via sandbox-exec -n no-internet (per-command wrapper).
Uses bash -c with proper quoting to prevent shell breakout (same as Linux).
"""

import logging
import shlex
import shutil

logger = logging.getLogger("hermes-vip.sandbox.macos")

_HERMES_USER = "_hermes"


def _get_sandbox_exec_path():
    return shutil.which("sandbox-exec")


def _build_macos_cmd(command: str, net_on: bool, profile_path: str) -> str:
    """Wrap command as _hermes user for file isolation.
    Add sandbox-exec -n no-internet when network is disabled.
    Uses bash -c with quoting to prevent shell breakout via ; | && ||."""

    # Base: file isolation via _hermes user, bash -c prevents breakout
    cmd = f"sudo -u {_HERMES_USER} bash -c {shlex.quote(command)}"

    # Network isolation via sandbox-exec (outer wrapper)
    if not net_on:
        sb_path = _get_sandbox_exec_path()
        if sb_path:
            cmd = f"{sb_path} -n no-internet {cmd}"

    return cmd


def apply_network(net_on: bool):
    """macOS: network control is per-command via sandbox-exec, not system-wide."""
    pass
