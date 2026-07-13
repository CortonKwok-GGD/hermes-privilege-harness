"""
Guard — Hermes VIP 安全守卫

单一责任：在 pre_tool_call 钩子中判断工具调用是否需要审批。

两个路径：
1. terminal("sudo xxx") → 拦截并重定向到 vip_sudo
2. vip_sudo(...) → 触发原生交互审批卡片，批准后自动通过 daemon 执行

Defense-in-depth: handler 入口必须验章（stamp/verify），
即使 Hermes backend 因任何原因绕过审批卡，handler 自己拒绝未盖章的命令。
"""

import json
import logging
import os
import re
import socket
import struct
import time
import uuid
from collections import defaultdict

logger = logging.getLogger("hermes-vip.guard")

REQUEST_SOCK = os.environ.get("VIP_REQUEST_SOCK", "/var/run/hermes-vip/request.sock")
BLOCKLIST_FILE = os.environ.get("VIP_BLOCKLIST_FILE", "/usr/local/etc/hermes-vip/blocklist.yaml")

# ── terminal sudo 拦截 ──
# \bsudo\b 覆盖: sudo, /usr/bin/sudo, sh -c 'sudo ...', eval "sudo ..."
SUDO_PATTERNS = [
    re.compile(r"\bsudo\b", re.IGNORECASE),
    re.compile(r"\bdoas\b", re.IGNORECASE),
    re.compile(r"\bpkexec\b", re.IGNORECASE),
    re.compile(r"\bsu\s+-", re.IGNORECASE),
    re.compile(r"""['"]sudo['"]""", re.IGNORECASE),
]

# SSH 远程命令（如 "ssh host sudo xxx"）中的提权由 SSH 认证负责，VIP 放行
_SSH_REMOTE_RE = re.compile(
    r"(?:^|\s)ssh\s+(?:-[a-zA-Z0-9]+\s+)*(?:\S+@)?\S+\s+", re.IGNORECASE
)


def _has_privilege_escalation(command: str) -> bool:
    """检测命令中是否包含提权尝试。SSH 远程命令放行。"""
    if _SSH_REMOTE_RE.search(command):
        return False
    for pat in SUDO_PATTERNS:
        if pat.search(command):
            return True
    return False


# ── Stamp 验证（defense-in-depth）──
# check() 盖章 → handler 验章 → handler 消章。
# 直接调 vip_sudo handler（绕过审批卡）会被拒绝。
_STAMP_TTL = 15  # handler 在审批批准后立刻执行，15s 够宽裕
_stamps: dict[str, float] = {}


def _stamp(command: str):
    """Mark a command as having passed through the approval gate."""
    key = command[:120]
    _stamps[key] = time.time()
    now = time.time()
    for k in list(_stamps):
        if now - _stamps[k] > _STAMP_TTL * 2:
            del _stamps[k]


def _verify(command: str) -> bool:
    """Verify the command was stamped by check(). Returns True and clears stamp."""
    key = command[:120]
    ts = _stamps.pop(key, None)
    if ts is None:
        return False
    if time.time() - ts > _STAMP_TTL:
        return False
    return True


# ── 防循环 ──
_recent: dict[str, list[float]] = defaultdict(list)
_MAX_FAIL = 3
_WINDOW = 60
_COOLDOWN = 120
_blocked_until: dict[str, float] = {}


def _check_loop(command: str, exit_code: int):
    """检测是否陷入循环。返回阻断消息或 None。"""
    key = command[:60]
    now = time.time()

    if key in _blocked_until and now < _blocked_until[key]:
        remaining = int(_blocked_until[key] - now)
        return (
            f"This command has failed repeatedly. "
            f"Auto-blocked for {remaining}s to prevent loop. "
            f"Try a different approach or wait."
        )

    _recent[key] = [t for t in _recent[key] if now - t < _WINDOW]

    if exit_code != 0:
        _recent[key].append(now)
        if len(_recent[key]) >= _MAX_FAIL:
            _blocked_until[key] = now + _COOLDOWN
            _recent[key].clear()
            return (
                f"Command failed {_MAX_FAIL} times in {_WINDOW}s. "
                f"Auto-blocked for {_COOLDOWN}s. "
                f"This is likely a system-level issue, not a retry problem."
            )
    else:
        _recent[key].clear()
        if key in _blocked_until:
            del _blocked_until[key]

    return None


# ── vip_sudo 黑名单 ──
# 即使用户批准了审批卡，以下操作也不允许执行。
_BLOCKLIST_CACHE: tuple[float, list[tuple[re.Pattern, str]]] = (0, [])
_BLOCKLIST_CACHE_TTL = 60

# 硬编码后备黑名单 — 当 blocklist.yaml 不可读时使用，防止 fail-open
_FALLBACK_BLOCKLIST: list[tuple[str, str]] = [
    (r"\buseradd\b|\badduser\b", "创建新用户"),
    (r"\bpasswd\b|\bchpasswd\b", "修改密码"),
    (r"\busermod\b.*-G\s+.*\b(sudo|wheel)\b", "赋予用户 sudo 权限"),
    (r"\bvisudo\b|/etc/sudoers", "编辑 sudoers 文件"),
    (r"\brm\s+.*-r.*f.*\s+/|rm\s+.*--no-preserve-root", "删除根目录"),
    (r"\bmkfs\b|dd\s+.*of=/dev/", "格式化或覆写磁盘"),
    (r"\bchmod\s+.*[67]77\s+/|\bchmod\s+.*\+s\b", "全局提权或设置 SUID"),
    (r"\bssh-keygen\b.*-f.*authorized|>>\s*\S*authorized_keys", "写入 SSH authorized_keys"),
    (r"\bcrontab\b\s+-[^l]|^\s*@reboot\b", "编辑 crontab 或持久化任务"),
    (r"\biptables\s+.*-F\b|\bufw\s+disable\b", "关闭防火墙"),
]


def _load_blocklist() -> list[tuple[re.Pattern, str]]:
    """Load blocklist from config file. Falls back to hardcoded rules if file unreadable."""
    global _BLOCKLIST_CACHE
    now = time.time()
    if now - _BLOCKLIST_CACHE[0] < _BLOCKLIST_CACHE_TTL:
        return _BLOCKLIST_CACHE[1]

    try:
        import yaml
    except ImportError:
        patterns = _compile_fallback()
        _BLOCKLIST_CACHE = (now, patterns)
        return patterns

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
    except FileNotFoundError:
        logger.warning("blocklist file not found, using fallback: %s", BLOCKLIST_FILE)
        patterns = _compile_fallback()
    except Exception as e:
        logger.warning("failed to load blocklist, using fallback: %s", e)
        patterns = _compile_fallback()

    _BLOCKLIST_CACHE = (now, patterns)
    return patterns


def _compile_fallback() -> list[tuple[re.Pattern, str]]:
    """Compile hardcoded fallback blocklist."""
    return [(re.compile(pat, re.IGNORECASE), label) for pat, label in _FALLBACK_BLOCKLIST]


def _check_blocklist(command: str) -> tuple[bool, str]:
    """Check command against blocklist. Returns (blocked, reason)."""
    for pat, label in _load_blocklist():
        if pat.search(command):
            return True, label
    return False, ""


# ── pre_tool_call 主入口 ──


def check(tool_name: str, args: dict):
    """
    pre_tool_call 钩子。
    返回:
      None → 放行（不拦截）
      {"action": "block", "message": "..."} → 拦截，显示错误
      {"action": "approve", "message": "...", "rule_key": "..."}
        → 触发原生审批卡片（方向键/网关按钮）
    """
    command = args.get("command", "") if isinstance(args, dict) else ""

    if tool_name == "terminal" and _has_privilege_escalation(command):
        return {
            "action": "block",
            "message": (
                "Sudo is not available via the terminal tool.\n"
                "Use the vip_sudo tool for privileged commands."
            ),
        }

    if tool_name == "vip_sudo":
        _stamp(command)
        return {
            "action": "approve",
            "message": f"Execute with root: {command[:80]}",
            "rule_key": "vip:sudo",
        }

    return None


# ── vip_sudo 工具 handler ──


def vip_sudo(command: str, reason: str = "") -> str:
    """
    vip_sudo 工具 handler。
    在原生审批卡片批准后执行：
    1. 验章 — 拒绝未经 check() 盖章的命令（defense-in-depth）
    2. 黑名单检查 — 高危操作提示用户手动执行
    3. 提交到 daemon
    4. 阻塞等 daemon 执行结果
    5. 返回结果给 LLM
    """
    if not command:
        return json.dumps({"error": "command required", "exit_code": -1})

    # ── Defense-in-depth: 必须经过 check() 盖章 ──
    if not _verify(command):
        logger.error(
            "REJECTED unapproved vip_sudo command (pid=%s): %s",
            os.getpid(), command[:120],
        )
        return json.dumps({
            "error": "REJECTED: command was not approved through the privilege gate",
            "exit_code": -1,
        })

    # ── 黑名单检查 ──
    blocked, label = _check_blocklist(command)
    if blocked:
        logger.warning(
            "BLOCKED dangerous vip_sudo command (pid=%s, rule=%s): %s",
            os.getpid(), label, command[:120],
        )
        return json.dumps({
            "error": (
                f"BLOCKED: {label}\n\n"
                f"This operation is blocked by VIP security policy. "
                f"It can modify system integrity, create persistent access, "
                f"or cause irreversible damage.\n\n"
                f"Execute this command manually in a terminal:\n\n"
                f"  {command}\n\n"
                f"To allow this operation permanently, "
                f"edit the blocklist: {BLOCKLIST_FILE}"
            ),
            "exit_code": -1,
        })

    # 1. 连接 daemon 提交直接执行请求
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

    # 2. 收结果
    try:
        raw = _recv_all(sock, 4)
        if not raw or len(raw) < 4:
            sock.close()
            return json.dumps({"error": "daemon closed", "exit_code": -1})
        mlen = struct.unpack("!I", raw)[0]
        data = _recv_all(sock, mlen)
        if len(data) != mlen:
            sock.close()
            return json.dumps({"error": "incomplete response from daemon", "exit_code": -1})
        result = json.loads(data.decode())
        sock.close()
    except Exception as exc:
        sock.close()
        return json.dumps({"error": f"read result failed: {exc}", "exit_code": -1})

    # 3. 解析结果返回
    status = result.get("status", "")
    if status == "approved":
        r = result.get("result", {})
        stdout = r.get("stdout", "")
        stderr = r.get("stderr", "")
        ec = r.get("exit_code", -1)

        loop_msg = _check_loop(command, ec)
        if loop_msg:
            return loop_msg

        if ec == 0:
            return stdout or json.dumps({"status": "ok", "exit_code": 0})
        return json.dumps({"error": stderr or f"exit {ec}", "exit_code": ec})
    elif status == "denied":
        return json.dumps({"error": "Request denied", "exit_code": -1})
    elif status == "timeout":
        return json.dumps({"error": "Approval timed out", "exit_code": -1})
    else:
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
