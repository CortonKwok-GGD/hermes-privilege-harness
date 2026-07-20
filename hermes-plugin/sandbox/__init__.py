"""
Sandbox — platform dispatcher for Hermes VIP v8.0

Shared config/state functions plus platform-aware sandbox command builder.
Delegates to sandbox/linux.py (bwrap) or sandbox/macos.py (sandbox-exec).
"""

import json
import logging
import os
import shlex
import shutil
import subprocess
import sys
import threading
import time

logger = logging.getLogger("hermes-vip.sandbox")

_lock = threading.Lock()

_CONFIG_PATH = os.environ.get(
    "VIP_CONFIG",
    os.path.expanduser("~/.hermes/plugins/hermes-vip/config.yaml"),
)

_SB_PROFILE = os.environ.get(
    "VIP_SB_PROFILE",
    os.path.expanduser("~/.hermes/plugins/hermes-vip/hermes-vip.sb"),
)


# ── Platform detection ──

IS_MACOS = sys.platform == "darwin"
IS_LINUX = sys.platform == "linux"


# ── Config management (shared) ──


def load_config() -> dict:
    cfg = {}
    try:
        import yaml as yamllib
        with open(_CONFIG_PATH) as f:
            cfg = yamllib.safe_load(f) or {}
    except FileNotFoundError:
        pass
    except Exception as e:
        logger.debug("config load failed: %s", e)
    return cfg.get("vip", cfg)


def sandbox_enabled() -> bool:
    return load_config().get("sandbox", {}).get("enabled", True)


def vip_sudo_enabled() -> bool:
    return load_config().get("vip_sudo", {}).get("enabled", True)


def network_enabled() -> bool:
    return load_config().get("sandbox", {}).get("network", False)


def _write_config_yaml(key: str, subkey: str, val: bool):
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


# ── Sandbox detection (shared) ──

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


# ── Mounts (shared, reads config) ──


def _get_sandbox_mounts() -> list[tuple[str, str, str]]:
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


def sandbox_available() -> bool:
    """Check if the platform sandbox tool is available."""
    if IS_LINUX:
        from . import linux as sb
        return sb._get_bwrap_path() is not None
    elif IS_MACOS:
        from . import macos as sb
        return sb._get_sandbox_exec_path() is not None
    return False


def build_sandbox_cmd(command: str) -> str:
    """Wrap a shell command in the platform-appropriate sandbox.
    Returns original command unchanged if sandboxing is unavailable."""
    if IS_LINUX:
        from . import linux as sb
        return sb._build_linux_cmd(command, _get_sandbox_mounts(), network_enabled())
    elif IS_MACOS:
        from . import macos as sb
        return sb._build_macos_cmd(command, _get_sandbox_mounts(), network_enabled(), _SB_PROFILE)
    return command
