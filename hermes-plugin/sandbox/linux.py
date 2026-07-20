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


def apply_mount_acls(mounts: list[tuple[str, str, str]]):
    uid = _get_hermes_uid()
    if uid <= 0:
        logger.warning("_hermes user not found, skipping mount ACLs")
        return

    # Collect unique parent directory chains for traversal
    parent_dirs = set()
    for flag, path, _ in mounts:
        if not os.path.exists(path):
            logger.debug("mount ACL: path not found, skipping: %s", path)
            continue
        # Ensure _hermes can traverse down to this path
        parent = os.path.dirname(path)
        while parent and parent != "/" and parent not in parent_dirs:
            parent_dirs.add(parent)
            parent = os.path.dirname(parent)

    # Grant traversal (rx) on parent chain
    for pdir in sorted(parent_dirs, key=len):
        if not os.path.exists(pdir):
            continue
        subprocess.run(["sudo", "setfacl", "-x", f"u:{uid}", pdir],
                       capture_output=True, timeout=10)
        subprocess.run(["sudo", "setfacl", "-m", f"u:{uid}:--x", pdir],
                       capture_output=True, timeout=10)
        logger.debug("parent ACL: %s rx", pdir)

    for flag, path, _ in mounts:
        if not os.path.exists(path):
            continue
        writable = (flag == "--bind")
        perms = "rwx" if writable else "rx"

        # Clear old ACL, set new one recursively
        subprocess.run(["sudo", "setfacl", "-x", f"u:{uid}", path],
                       capture_output=True, timeout=10)
        subprocess.run(["sudo", "setfacl", "-R", "-m", f"u:{uid}:{perms}", path],
                       capture_output=True, timeout=30)
        subprocess.run(["sudo", "setfacl", "-R", "-m", f"d:u:{uid}:{perms}", path],
                       capture_output=True, timeout=30)
        logger.info("mount ACL: %s %s (writable=%s)", path, perms, writable)
