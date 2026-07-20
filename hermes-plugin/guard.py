"""
Guard — Hermes VIP security guard v8.0

Single responsibility: intercept tool calls in pre_tool_call hook.
Block messages are state-aware: they adapt to sandbox/vip_sudo config.
"""

import hashlib
import json
import logging
import os
import re
import shlex
import socket
import struct
import subprocess
import time
import uuid
from collections import defaultdict

import threading

try:
    from . import sandbox  # plugin package load
except ImportError:
    import sandbox         # standalone test load

logger = logging.getLogger("hermes-vip.guard")

_lock = threading.Lock()

REQUEST_SOCK = os.environ.get("VIP_REQUEST_SOCK", "/var/run/hermes-vip/request.sock")
BLOCKLIST_FILE = os.environ.get("VIP_BLOCKLIST_FILE", "/usr/local/etc/hermes-vip/blocklist.yaml")

for _env_path in [("VIP_REQUEST_SOCK", REQUEST_SOCK), ("VIP_BLOCKLIST_FILE", BLOCKLIST_FILE)]:
    _name, _val = _env_path
    if not _val.startswith("/") or ".." in _val:
        raise ValueError(f"VIP: {_name} must be an absolute path without '..', got: {_val}")


def _sudo_block_message() -> str:
    """Return state-aware block message for terminal sudo."""
    if sandbox.vip_sudo_enabled():
        return "Use vip_sudo for privileged commands."
    if sandbox.sandbox_enabled():
        return "vip_sudo disabled in sandbox. Ask the user to run /vipsudo on in chat."
    return ""

def _vipsudo_block_message() -> str:
    """Return block message when vip_sudo tool is called but disabled."""
    return "vip_sudo is disabled. Use terminal sudo directly."


# ── sudo / git push patterns ──

SUDO_PATTERNS = [
    re.compile(r"\bsudo\b", re.IGNORECASE),
    re.compile(r"\bdoas\b", re.IGNORECASE),
    re.compile(r"\bpkexec\b", re.IGNORECASE),
    re.compile(r"\bsu\s+-", re.IGNORECASE),
    re.compile(r"""['"]sudo['"]""", re.IGNORECASE),
]

_SSH_REMOTE_RE = re.compile(
    r"(?:^|\s)ssh\s+(?:-[a-zA-Z0-9]+(?:=\S+)?\s+)*(?:\S+@)?\S+\s+", re.IGNORECASE
)

_GIT_PUSH_RE = re.compile(r"\bgit\s+push\b", re.IGNORECASE)


def _is_git_push_operation(command: str) -> bool:
    return bool(_GIT_PUSH_RE.search(command))


def _has_privilege_escalation(command: str) -> bool:
    if _SSH_REMOTE_RE.search(command):
        return False
    for pat in SUDO_PATTERNS:
        if pat.search(command):
            return True
    return False


# ── Stamp verification ──

_STAMP_TTL = 15
_stamps: dict[str, float] = {}


def _stamp(command: str):
    key = hashlib.sha256(command.encode()).hexdigest()
    with _lock:
        _stamps[key] = time.time()
        now = time.time()
        for k in list(_stamps):
            if now - _stamps[k] > _STAMP_TTL * 2:
                del _stamps[k]


def _verify(command: str) -> bool:
    key = hashlib.sha256(command.encode()).hexdigest()
    with _lock:
        ts = _stamps.pop(key, None)
    if ts is None:
        return False
    if time.time() - ts > _STAMP_TTL:
        return False
    return True


# ── Loop detection ──

_recent: dict[str, list[float]] = defaultdict(list)
_MAX_FAIL = 3
_WINDOW = 60
_COOLDOWN = 120
_blocked_until: dict[str, float] = {}


def _check_loop(command: str, exit_code: int) -> str | None:
    key = hashlib.sha256(command.encode()).hexdigest()
    now = time.time()
    if key in _blocked_until and now < _blocked_until[key]:
        remaining = int(_blocked_until[key] - now)
        return json.dumps({"error": f"Command blocked for {remaining}s (loop).", "exit_code": -1})
    with _lock:
        _recent[key] = [t for t in _recent[key] if now - t < _WINDOW]
    if exit_code != 0:
        with _lock:
            _recent[key].append(now)
            if len(_recent[key]) >= _MAX_FAIL:
                _blocked_until[key] = now + _COOLDOWN
                _recent[key].clear()
                return json.dumps({"error": f"Command failed {_MAX_FAIL} times. Auto-blocked.", "exit_code": -1})
    else:
        with _lock:
            _recent[key].clear()
            if key in _blocked_until:
                del _blocked_until[key]
    return None


# ── Blocklist ──

_BLOCKLIST_CACHE: tuple[float, list[tuple[re.Pattern, str]]] = (0, [])
_BLOCKLIST_CACHE_TTL = 60

_FALLBACK_BLOCKLIST: list[tuple[str, str]] = [
    (r"\buseradd\b|\badduser\b", "create user"),
    (r"\bpasswd\b|\bchpasswd\b", "change password"),
    (r"\busermod\b.*-G\s+.*\b(sudo|wheel)\b", "grant sudo"),
    (r"\bvisudo\b|/etc/sudoers", "edit sudoers"),
    (r"\brm\b\s+(?:-[rRfF]+\s+)*\S+/\s*$|rm\s+.*--no-preserve-root", "delete root"),
    (r"\bmkfs\b|dd\s+.*of=/dev/", "format disk"),
    (r"\bchmod\b\s+(?:-[a-zA-Z]+\s+)*[67]77\s+\S+|chmod\s+.*\+s\b", "setuid"),
    (r"\bssh-keygen\b.*-f.*authorized|>>\s*\S*authorized_keys", "write authorized_keys"),
    (r"\bcrontab\b\s+-[^l]|^\s*@reboot\b", "edit crontab"),
    (r"\biptables\s+.*-F\b|\bufw\s+disable\b", "disable firewall"),
]


def _load_blocklist() -> list[tuple[re.Pattern, str]]:
    global _BLOCKLIST_CACHE
    now = time.time()
    with _lock:
        if now - _BLOCKLIST_CACHE[0] < _BLOCKLIST_CACHE_TTL:
            return _BLOCKLIST_CACHE[1]
    try:
        import yaml
        with open(BLOCKLIST_FILE) as f:
            raw = yaml.safe_load(f) or {}
        rules = []
        for item in raw.get("blocklist", []):
            pattern = item.get("pattern")
            label = item.get("label", "unknown")
            if pattern:
                rules.append((re.compile(pattern), label))
        with _lock:
            _BLOCKLIST_CACHE = (now, rules)
        return rules
    except Exception:
        rules = [(re.compile(p), l) for p, l in _FALLBACK_BLOCKLIST]
        with _lock:
            _BLOCKLIST_CACHE = (now, rules)
        return rules


def _check_blocklist(command: str) -> tuple[bool, str]:
    for pattern, label in _load_blocklist():
        if pattern.search(command):
            return True, label
    return False, ""


# ── check() — 三条路 ──

_FILE_TOOL_HINTS = {
    "read_file": "Use terminal: cat <path>",
    "write_file": "Use terminal: echo/heredoc > <path>",
    "patch": "Use terminal: sed 's/old/new/' <file>",
    "search_files": "Use terminal: grep -r <pattern> <path>",
    "vision_analyze": "Use terminal: python3 -c \"from PIL import Image; Image.open('path')\"",
}


def check(tool_name: str, args: dict, **kw) -> dict | None:
    if sandbox.in_sandbox():
        return None

    sb_on = sandbox.sandbox_enabled()
    vs_on = sandbox.vip_sudo_enabled()

    # ── 出路 3: vip_sudo（唯一出口）──
    if tool_name == "vip_sudo":
        if not vs_on:
            return {"action": "block", "message": _vipsudo_block_message()}
        command = args.get("command", "")
        _stamp(command)
        return {
            "action": "approve",
            "message": f"sudo: {command[:80]}",
            "rule_key": "vip:sudo",
        }

    if not sb_on:
        return None

    # ── 出路 1: 子进程 → bwrap 包装，透明放行 ──
    if tool_name == "terminal":
        cmd = args.get("command", "")
        if _has_privilege_escalation(cmd):
            if vs_on:
                return {"action": "block", "message": _sudo_block_message()}
            return None  # system sudo
        wrapped = sandbox.build_sandbox_cmd(cmd)
        if wrapped != cmd:
            args["command"] = wrapped
        return None

    if tool_name == "execute_code":
        code = args.get("code", "")
        # Wrap python execution in sandbox
        if sandbox.sandbox_available() and code:
            wrapped_cmd = sandbox.build_sandbox_cmd(f"python3 -c {shlex.quote(code)}")
            args["code"] = f"""import subprocess
result = subprocess.run({shlex.quote(wrapped_cmd)}, shell=True, capture_output=True, text=True, timeout=60)
print(result.stdout or result.stderr)
"""
        return None

    # ── 出路 2: 进程内函数 → block，引导用 terminal ──
    if tool_name in _FILE_TOOL_HINTS:
        return {"action": "block", "message": _FILE_TOOL_HINTS[tool_name]}

    # ── 放行白名单（已知不碰文件系统的数据工具）──
    if tool_name in ("todo", "memory", "session_search", "delegate_task", "clarify", "skill_view", "skills_list", "skill_manage", "cronjob", "process", "text_to_speech", "fact_store", "fact_feedback", "project_create", "project_list", "project_switch", "read_terminal", "close_terminal"):
        return None

    # 未知工具 → 默认拦，指向 vip_sudo
    return {"action": "block", "message": "Tool not available in sandbox. Use vip_sudo."}


# ── vip_sudo handler ──

def vip_sudo(command: str, reason: str = "") -> str:
    if not command:
        return json.dumps({"error": "command required", "exit_code": -1})

    if not _verify(command):
        logger.error("REJECTED unapproved vip_sudo (pid=%s): %s", os.getpid(), command[:120])
        return json.dumps({"error": "REJECTED: command not approved", "exit_code": -1})

    blocked, label = _check_blocklist(command)
    if blocked:
        logger.warning("BLOCKED vip_sudo (pid=%s, rule=%s): %s", os.getpid(), label, command[:120])
        return json.dumps({"error": f"BLOCKED: {label}\nExecute manually:\n  {command}\n", "exit_code": -1})

    if _is_git_push_operation(command):
        try:
            result = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=120)
            if result.returncode == 0:
                return result.stdout or json.dumps({"status": "ok", "exit_code": 0})
            return json.dumps({"error": result.stderr or f"exit {result.returncode}", "exit_code": result.returncode})
        except subprocess.TimeoutExpired:
            return json.dumps({"error": "git push timed out", "exit_code": -1})
        except Exception as e:
            return json.dumps({"error": f"git push failed: {e}", "exit_code": -1})

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(600)
    try:
        sock.connect(REQUEST_SOCK)
    except OSError as exc:
        return json.dumps({"error": "VIP daemon not running", "exit_code": -1})

    req = {
        "type": "sudo_execute",
        "command": command,
        "reason": reason or "privilege request",
        "origin": {"channel": "vip_sudo", "timestamp": time.time()},
    }
    payload = json.dumps(req).encode()
    try:
        sock.sendall(struct.pack("!I", len(payload)) + payload)
    except OSError as exc:
        sock.close()
        return json.dumps({"error": f"submit failed: {exc}", "exit_code": -1})

    try:
        raw_len = sock.recv(4)
        if len(raw_len) < 4:
            return json.dumps({"error": "daemon disconnected", "exit_code": -1})
        resp_len = struct.unpack("!I", raw_len)[0]
        data = b""
        while len(data) < resp_len:
            chunk = sock.recv(resp_len - len(data))
            if not chunk:
                break
            data += chunk
        result = json.loads(data.decode())
        return json.dumps(result)
    except Exception as exc:
        return json.dumps({"error": f"daemon error: {exc}", "exit_code": -1})
    finally:
        sock.close()
