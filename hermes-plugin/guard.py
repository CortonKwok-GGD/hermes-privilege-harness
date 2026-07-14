"""
VIP Guard — passive privilege harness.

Philosophy:
  - Hermes handles: dangerous command detection, approval cards, blocking sudo
  - VIP handles: execution via daemon (only after proven approval)

Security: vip_sudo handler refuses any command it hasn't stamped in check().
          A command must pass through the approval gate before it executes.
"""

import hashlib
import json
import logging
import os
import re
import socket
import struct
import time

logger = logging.getLogger("hermes-vip.guard")

REQUEST_SOCK = os.environ.get("VIP_REQUEST_SOCK", "/var/run/hermes-vip/request.sock")
BLOCKLIST_FILE = os.environ.get("VIP_BLOCKLIST_FILE", "/usr/local/etc/hermes-vip/blocklist.yaml")

# ── vip_sudo 黑名单（操作级）──
# 审批批准后，匹配的命令仍然被拒绝——防止高危操作即使是用户批准的。
_BLOCKLIST_CACHE: tuple[float, list[tuple[re.Pattern, str]]] = (0, [])
_BLOCKLIST_CACHE_TTL = 60

_FALLBACK_BLOCKLIST: list[tuple[str, str]] = [
    (r"\buseradd\b|\badduser\b", "创建新用户"),
    (r"\bpasswd\b|\bchpasswd\b", "修改密码"),
    (r"\busermod\b.*-G\s+.*\b(sudo|wheel)\b", "赋予用户 sudo 权限"),
    (r"\bvisudo\b|/etc/sudoers", "编辑 sudoers 文件"),
    (r"\brm\b\s+(?:-[rRfF]+\s+)*\S+/\s*$|rm\s+.*--no-preserve-root", "删除根目录"),
    (r"\bmkfs\b|dd\s+.*of=/dev/", "格式化或覆写磁盘"),
    (r"\bchmod\b\s+(?:-[a-zA-Z]+\s+)*[67]77\s+\S+|chmod\s+.*\+s\b", "全局提权或设置 SUID"),
    (r"\bssh-keygen\b.*-f.*authorized|>>\s*\S*authorized_keys", "写入 SSH authorized_keys"),
    (r"\bcrontab\b\s+-[^l]|^\s*@reboot\b", "编辑 crontab 或持久化任务"),
    (r"\biptables\s+.*-F\b|\bufw\s+disable\b", "关闭防火墙"),
]


def _load_blocklist() -> list[tuple[re.Pattern, str]]:
    global _BLOCKLIST_CACHE
    now = time.time()
    if now - _BLOCKLIST_CACHE[0] < _BLOCKLIST_CACHE_TTL:
        return _BLOCKLIST_CACHE[1]
    try:
        import yaml
    except ImportError:
        return _BLOCKLIST_CACHE[1] if _BLOCKLIST_CACHE[1] else _compile_fallback()
    patterns = []
    try:
        with open(BLOCKLIST_FILE) as f:
            cfg = yaml.safe_load(f) or {}
        for entry in cfg.get("blocked_patterns", []):
            pat = entry.get("pattern", "")
            label = entry.get("label", pat)
            if pat:
                patterns.append((re.compile(pat, re.IGNORECASE), label))
        if not patterns:
            raise ValueError("empty blocklist")
    except Exception:
        logger.warning("blocklist load failed, using fallback")
        patterns = _compile_fallback()
    _BLOCKLIST_CACHE = (now, patterns)
    return patterns


def _compile_fallback() -> list[tuple[re.Pattern, str]]:
    return [(re.compile(pat, re.IGNORECASE), label) for pat, label in _FALLBACK_BLOCKLIST]


def _check_blocklist(command: str) -> tuple[bool, str]:
    for pat, label in _load_blocklist():
        if pat.search(command):
            return True, label
    return False, ""

# ── Defense-in-depth: commands must be stamped by check() before execution ──
# check() stores a stamp → handler verifies it → handler clears it.
# A direct call to vip_sudo (bypassing the approval card) will be rejected.
_STAMP_TTL = 30  # seconds — generous: handler runs immediately after approval
_stamps: dict[str, float] = {}


def _stamp(command: str):
    """Mark a command as having passed through the approval gate."""
    key = hashlib.sha256(command.encode()).hexdigest()
    _stamps[key] = time.time()
    # Clean expired stamps
    now = time.time()
    for k in list(_stamps):
        if now - _stamps[k] > _STAMP_TTL * 2:
            del _stamps[k]


def _verify(command: str) -> bool:
    """Verify the command was stamped by check(). Returns True and clears stamp."""
    key = hashlib.sha256(command.encode()).hexdigest()
    ts = _stamps.pop(key, None)
    if ts is None:
        return False
    if time.time() - ts > _STAMP_TTL:
        return False
    return True


# ── pre_tool_call ──

def check(tool_name: str, args: dict):
    """Stamp vip_sudo commands before Hermes shows the approval card."""
    if tool_name == "vip_sudo":
        command = args.get("command", "") if isinstance(args, dict) else ""
        _stamp(command)
        return {
            "action": "approve",
            "message": f"sudo: {command[:80]}",
        }
    return None


# ── vip_sudo handler ──

def vip_sudo(command: str, reason: str = "") -> str:
    """
    Execute via daemon. REFUSES to execute unless check() stamped this command first.
    Called only after Hermes native card approval.
    """
    if not command:
        return json.dumps({"error": "command required", "exit_code": -1})

    if not _verify(command):
        return json.dumps({
            "error": "REJECTED: command was not approved through the privilege gate",
            "exit_code": -1,
        })

    # ── 操作级黑名单 ──
    # 即使用户批准了，高危操作也被拒绝（需要手动执行）
    blocked, label = _check_blocklist(command)
    if blocked:
        logger.warning(
            "BLOCKED dangerous command (rule=%s): %s", label, command[:120],
        )
        return json.dumps({
            "error": (
                f"BLOCKED: {label}\n\n"
                f"This operation is blocked by VIP security policy.\n\n"
                f"Execute manually:\n  {command}\n\n"
                f"To allow: edit {BLOCKLIST_FILE}"
            ),
            "exit_code": -1,
        })

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(600)

    try:
        sock.connect(REQUEST_SOCK)
    except OSError as exc:
        logger.error("daemon unreachable: %s", exc)
        return json.dumps({"error": "VIP daemon not running", "exit_code": -1})

    req = {
        "type": "sudo_execute",
        "command": command,
        "reason": reason or "提权请求",
        "origin": {"channel": "vip_sudo", "timestamp": time.time()},
    }
    payload = json.dumps(req).encode()

    try:
        sock.sendall(struct.pack("!I", len(payload)) + payload)
    except OSError as exc:
        sock.close()
        return json.dumps({"error": f"submit failed: {exc}", "exit_code": -1})

    try:
        raw = _recv_all(sock, 4)
        if not raw or len(raw) < 4:
            sock.close()
            return json.dumps({"error": "daemon closed", "exit_code": -1})
        mlen = struct.unpack("!I", raw)[0]
        data = _recv_all(sock, mlen)
        if len(data) != mlen:
            sock.close()
            return json.dumps({"error": "incomplete response", "exit_code": -1})
        result = json.loads(data.decode())
        sock.close()
    except Exception as exc:
        sock.close()
        return json.dumps({"error": f"read failed: {exc}", "exit_code": -1})

    status = result.get("status", "")
    if status == "approved":
        r = result.get("result", {})
        stdout = r.get("stdout", "")
        stderr = r.get("stderr", "")
        ec = r.get("exit_code", -1)
        if ec == 0:
            return stdout or json.dumps({"status": "ok", "exit_code": 0})
        return json.dumps({"error": stderr or f"exit {ec}", "exit_code": ec})
    return json.dumps({"error": result.get("error", "unknown"), "exit_code": -1})


def _recv_all(sock: socket.socket, size: int) -> bytes:
    if size <= 0:
        return b""
    chunks, remaining = [], size
    while remaining > 0:
        c = sock.recv(remaining)
        if not c:
            break
        chunks.append(c)
        remaining -= len(c)
    return b"".join(chunks)
