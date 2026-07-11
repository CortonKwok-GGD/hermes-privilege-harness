"""
Guard — Hermes VIP 安全守卫

单一责任：在 pre_tool_call 钩子中判断工具调用是否需要审批。

两个路径：
1. terminal("sudo xxx") → 拦截并重定向到 vip_sudo
2. vip_sudo(...) → 触发原生交互审批卡片，批准后自动通过 daemon 执行
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
SUDO_RE = re.compile(r"^\s*sudo\s", re.IGNORECASE)

# ── 会话审批状态（插件内存，不写 config.yaml）──
_session_approved = False


# ── 防循环 ──
_recent: dict[str, list[float]] = defaultdict(list)
_MAX_FAIL = 3          # 连续失败 N 次后阻断
_WINDOW = 60           # 时间窗口（秒）
_COOLDOWN = 120        # 阻断持续秒数
_blocked_until: dict[str, float] = {}


def _check_loop(command: str, exit_code: int):
    """检测是否陷入循环。返回阻断消息或 None。"""
    key = command[:60]  # 用命令前缀做 key
    now = time.time()

    # 检查是否在阻断期
    if key in _blocked_until and now < _blocked_until[key]:
        remaining = int(_blocked_until[key] - now)
        return (
            f"This command has failed repeatedly. "
            f"Auto-blocked for {remaining}s to prevent loop. "
            f"Try a different approach or wait."
        )

    # 清理过期的记录
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
        # 成功后重置
        _recent[key].clear()
        if key in _blocked_until:
            del _blocked_until[key]

    return None


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

    if tool_name == "terminal" and SUDO_RE.match(command):
        return {
            "action": "block",
            "message": (
                "Sudo is not available via the terminal tool.\n"
                "Use the vip_sudo tool for privileged commands."
            ),
        }

    if tool_name == "vip_sudo":
        # 会话内已批准过 → 跳过审批
        if _session_approved:
            return None
        # 每次用随机 rule_key，防止 "always" 写入 config.yaml
        return {
            "action": "approve",
            "message": f"Execute with root: {command[:80]}",
            "rule_key": f"vip:sudo:{uuid.uuid4().hex[:12]}",
        }

    return None


# ── vip_sudo 工具 handler ──


def vip_sudo(command: str, reason: str = "") -> str:
    """
    vip_sudo 工具 handler。
    在原生审批卡片批准后执行：
    1. 提交到 daemon → 取 req_id
    2. 自动批准（原生卡片已认证用户）
    3. 阻塞等 daemon 执行结果
    4. 返回结果给 LLM
    """
    global _session_approved
    if not command:
        return json.dumps({"error": "command required", "exit_code": -1})

    # 1. 连接 daemon 提交直接执行请求（跳过审批，原生卡片已认证）
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

    # 2. 收结果（sudo_execute 直接返回，不需审批队列）
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

        # 防循环检查
        loop_msg = _check_loop(command, ec)
        if loop_msg:
            return loop_msg

        if ec == 0:
            _session_approved = True  # 只在成功执行后设置
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
