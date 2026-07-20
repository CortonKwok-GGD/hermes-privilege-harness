"""
Sandbox — bwrap isolation layer for Hermes VIP v8.0

Single source of truth for sandbox boundary:
  - Mount list is built from config.yaml (user-editable)
  - is_allowed_path() checks against the same mounts
  - build_bwrap_cmd() uses the same mounts for terminal wrapping
"""

import json
import logging
import os
import shlex
import subprocess
import threading
import time

logger = logging.getLogger("hermes-vip.sandbox")

_lock = threading.Lock()

_CONFIG_PATH = os.environ.get(
    "VIP_CONFIG",
    os.path.expanduser("~/.hermes/plugins/hermes-vip/config.yaml"),
)


def load_config() -> dict:
    """Load VIP config from YAML file. Always re-reads (no cache for toggle reliability)."""
    cfg = {}
    try:
        import yaml as yamllib
        with open(_CONFIG_PATH) as f:
            cfg = yamllib.safe_load(f) or {}
    except FileNotFoundError:
        pass
    except Exception as e:
        logger.debug("config load failed: %s", e)
    # Accept both flat (sandbox:) and nested (vip:sandbox:)
    return cfg.get("vip", cfg)


def _get_sandbox_mounts() -> list[tuple[str, str, str]]:
    """Build mount list from config. Returns [(flag, src, dst), ...]."""
    cfg = load_config()
    sandbox_cfg = cfg.get("sandbox", {})
    mounts = sandbox_cfg.get("mounts", [])
    result = []
    for m in mounts:
        raw_path = m.get("path", "")
        if not raw_path:
            continue
        path = os.path.expandvars(os.path.expanduser(raw_path))
        flag = "--bind" if m.get("writable", False) else "--ro-bind"
        result.append((flag, path, path))
    return result


# ── Sandbox detection ──

_SANDBOX_MARKERS = ["/.dockerenv", "/run/.containerenv", "/.bwrapenv"]


def in_sandbox() -> bool:
    if os.environ.get("SANDBOXED") == "1":
        return True
    for marker in _SANDBOX_MARKERS:
        if os.path.exists(marker):
            return True
    try:
        with open("/proc/1/cgroup") as f:
            if "docker" in f.read() or "kubepods" in f.read():
                return True
    except Exception:
        pass
    return False


def _get_bwrap_path():
    """Return bwrap path or None if not available."""
    try:
        r = subprocess.run(["which", "bwrap"], capture_output=True, text=True, timeout=5)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except Exception:
        pass
    return None


# ── bwrap base arguments ──

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
]


def build_bwrap_cmd(command: str) -> str:
    """Wrap a shell command in bwrap sandbox, using config mounts."""
    bwrap_path = _get_bwrap_path()
    if not bwrap_path:
        return command
    args = [bwrap_path] + _BWRAP_BASE
    if not network_enabled():
        args.append("--unshare-net")
    for flag, src, dst in _get_sandbox_mounts():
        args.extend([flag, src, dst])
    args.extend(["--", "/usr/bin/bash", "-c", command])
    return " ".join(shlex.quote(a) for a in args)


def is_allowed_path(path: str) -> bool:
    """Check if path is within sandbox mount boundary (from config)."""
    if not path:
        return False
    normalized = os.path.normpath(os.path.expanduser(path))
    for _flag, src, _dst in _get_sandbox_mounts():
        if normalized.startswith(src) or normalized == src:
            return True
    return False


def sandbox_enabled() -> bool:
    return load_config().get("sandbox", {}).get("enabled", True)


def vip_sudo_enabled() -> bool:
    return load_config().get("vip_sudo", {}).get("enabled", True)


def network_enabled() -> bool:
    return load_config().get("sandbox", {}).get("network", False)


def _write_config_yaml(key: str, subkey: str, val: bool):
    """Write a single config value to YAML file. No cache — next read picks it up."""
    import yaml as yamllib
    try:
        with open(_CONFIG_PATH) as f:
            raw = yamllib.safe_load(f) or {}
    except Exception:
        raw = {}
    target = raw.get("vip", raw)
    if key not in target or not isinstance(target[key], dict):
        target[key] = {}
    target[key][subkey] = val
    with open(_CONFIG_PATH, "w") as f:
        yamllib.dump(raw, f, default_flow_style=False)
        f.flush()
        os.fsync(f.fileno())
    logger.info("%s.%s set to %s", key, subkey, val)


def set_sandbox_enabled(val: bool):
    _write_config_yaml("sandbox", "enabled", val)


def set_vip_sudo_enabled(val: bool):
    _write_config_yaml("vip_sudo", "enabled", val)


def set_network_enabled(val: bool):
    _write_config_yaml("sandbox", "network", val)
