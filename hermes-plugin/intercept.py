"""
Intercept — 沙箱拦截 + 聊天窗口审批提示
"""

import json
import logging
import os
import re
import socket
import struct
import subprocess
import time

logger = logging.getLogger("hermes-vip.intercept")

REQUEST_SOCK = os.environ.get("VIP_REQUEST_SOCK", "/run/hermes-vip/request.sock")
KILL_FILE = "/etc/hermes-vip/kill_sudo"
SUDO_RE = re.compile(r"^\s*sudo\s")
BWRAP = "/usr/local/bin/hermes-bwrap-exec"


def handle_terminal(command: str, reason: str = "") -> dict:
    """
    处理 terminal 命令：
    1. 非 sudo → 先试 bwrap → 成功则返回结果
    2. sudo 或 bwrap 失败 → 走 VIP
    """
    is_sudo = bool(SUDO_RE.match(command))

    # 非 sudo 先试 bwrap
    if not is_sudo and os.path.exists(BWRAP):
        try:
            result = subprocess.run(
                [BWRAP, "/bin/bash", "-c", command],
                capture_output=True, text=True, timeout=30,
            )
            if result.returncode == 0:
                return {"action": "return_immediately", "result": result.stdout}
        except Exception:
            pass

    # sudo 或 bwrap 失败 → VIP
    if is_sudo or os.path.exists(BWRAP):
        return _vip_flow(command, reason or "提权请求")

    return None


def _vip_flow(command: str, reason: str) -> dict:
    """提交 VIP daemon，返回 chat 审批引导文字"""
    if os.path.exists(KILL_FILE):
        return {"action": "return_immediately", "result": "sudo: command not found"}

    # 连接 VIP daemon
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(10)
    try:
        sock.connect(REQUEST_SOCK)
    except (FileNotFoundError, ConnectionRefusedError) as exc:
        logger.warning("VIP daemon 未运行: %s", exc)
        return {"action": "return_immediately",
                "result": "需要管理员权限：/vip-pending"}

    # 提交
    req = {"type": "sudo_request", "command": command, "reason": reason,
           "origin": {"channel": "cli", "timestamp": time.time()}}
    payload = json.dumps(req).encode()
    sock.sendall(struct.pack("!I", len(payload)) + payload)

    # 收 pending 响应
    raw_len = sock.recv(4, socket.MSG_WAITALL)
    if not raw_len:
        sock.close()
        return {"action": "return_immediately", "result": "需要管理员权限：/vip-pending"}

    resp = json.loads(sock.recv(struct.unpack("!I", raw_len)[0], socket.MSG_WAITALL))
    req_id = resp.get("req_id", "")
    sock.close()

    if not req_id:
        return {"action": "return_immediately", "result": "需要管理员权限：/vip-pending"}

    # 聊天窗口显示审批卡（而不是弹窗）
    card = (
        f"\n🔐 提权请求 #{req_id[:8]}\n"
        f"  命令: {command[:60]}\n"
        f"  原因: {reason}\n"
        f"  /vip-approve {req_id[:8]}   — 批准\n"
        f"  /vip-deny {req_id[:8]}      — 拒绝"
    )

    return {"action": "return_immediately", "result": card}
