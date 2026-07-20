"""
Linux sandbox — _hermes user isolation for Hermes VIP v8.0

File isolation via dedicated _hermes user + ACL.
Network isolation via iptables -m owner (system-wide, no per-command wrapping).
"""

import logging
import re
import shlex
import subprocess

logger = logging.getLogger("hermes-vip.sandbox.linux")

_HERMES_USER = "_hermes"
_HERMES_UID = None


def _get_hermes_uid() -> int:
    global _HERMES_UID
    if _HERMES_UID is not None:
        return _HERMES_UID
    try:
        r = subprocess.run(["id", "-u", _HERMES_USER], capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            _HERMES_UID = int(r.stdout.strip())
    except Exception:
        _HERMES_UID = 0
    return _HERMES_UID or 0


def _build_linux_cmd(command: str) -> str:
    """Wrap command as _hermes user for file isolation.
    Uses bash -c with proper quoting to prevent shell breakout."""
    return f"sudo -u {_HERMES_USER} bash -c {shlex.quote(command)}"


def apply_network(net_on: bool):
    """Apply iptables rule based on network state.
    net_on=True:  remove block rule (allow network)
    net_on=False: add block rule (block network)"""
    uid = _get_hermes_uid()
    if uid <= 0:
        return

    rule = ["OUTPUT", "-m", "owner", "--uid-owner", str(uid), "-j", "DROP"]

    if net_on:
        # Remove block rule
        subprocess.run(["sudo", "iptables", "-D"] + rule,
                       capture_output=True, timeout=10)
        logger.info("iptables: removed block rule for uid %s", uid)
    else:
        # Check if rule already exists
        r = subprocess.run(["sudo", "iptables", "-C"] + rule,
                           capture_output=True, timeout=10)
        if r.returncode != 0:
            subprocess.run(["sudo", "iptables", "-A"] + rule,
                           capture_output=True, timeout=10)
            logger.info("iptables: added block rule for uid %s", uid)
        else:
            logger.info("iptables: block rule already exists for uid %s", uid)
