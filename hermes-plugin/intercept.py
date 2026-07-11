"""
Intercept — sudo 命令拦截层

运行在 Hermes 进程内。拦截所有 terminal("sudo ...") 命令，
转给 VIP daemon。

通知逻辑：
1. 先尝试桌面通知（notify-send / osascript）
2. 如果失败，自动返回引导消息，让用户在对话中输入 /vip-pending
"""

import json
import logging
import os
import platform
import re
import socket
import struct
import subprocess
import time

logger = logging.getLogger("hermes-vip.intercept")

REQUEST_SOCK = os.environ.get("VIP_REQUEST_SOCK", "/var/run/hermes-vip/request.sock")
SUDO_RE = re.compile(r"^\s*sudo\s")
KILL_FILE = "/etc/hermes-vip/kill_sudo"


def _notify_desktop(title: str, message: str) -> bool:
    """发送桌面通知，返回是否成功"""
    system = platform.system()
    try:
        if system == "Linux":
            # 尝试通过当前用户发送通知
            result = subprocess.run(
                ["notify-send", title, message, "-i", "dialog-password"],
                timeout=3, capture_output=True,
            )
            if result.returncode == 0:
                return True
            # 失败：可能没有 DISPLAY
            logger.warning("notify-send 失败: %s", result.stderr.decode()[:100])
            return False
        elif system == "Darwin":
            script = f'display notification "{message}" with title "{title}"'
            subprocess.run(
                ["osascript", "-e", script],
                timeout=3, capture_output=True,
            )
            return True
    except Exception as exc:
        logger.warning("桌面通知失败: %s", exc)
    return False


def _send_to_vip(command: str, reason: str) -> dict:
    """向 VIP daemon 提交提权请求，返回响应"""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(10)
    try:
        sock.connect(REQUEST_SOCK)
    except (FileNotFoundError, ConnectionRefusedError) as exc:
        logger.warning("VIP daemon 未运行: %s", exc)
        sock.close()
        return {"error": f"VIP daemon 未运行: {exc}"}

    req = {
        "type": "sudo_request",
        "command": command,
        "reason": reason,
        "origin": {"channel": "cli", "timestamp": time.time()},
    }
    payload = json.dumps(req).encode("utf-8")
    sock.sendall(struct.pack("!I", len(payload)) + payload)

    # 等回应（含 req_id）
    raw_len = sock.recv(4, socket.MSG_WAITALL)
    if raw_len:
        msg_len = struct.unpack("!I", raw_len)[0]
        resp = json.loads(sock.recv(msg_len, socket.MSG_WAITALL))
        sock.close()
        return resp

    sock.close()
    return {"error": "无响应"}


def handle_vip_sudo(command: str, reason: str = "提权请求") -> str:
    """处理 sudo 命令——提交 VIP daemon 并返回伪装错误"""

    # 1. Kill 文件检查
    if os.path.exists(KILL_FILE):
        logger.info("kill file 存在，拒绝 sudo 请求")
        return "sudo: command not found"

    # 2. 提交 VIP daemon
    resp = _send_to_vip(command, reason)
    req_id = resp.get("req_id", "")

    if resp.get("error"):
        # daemon 不可用，返回标准 sudo 错误
        logger.warning("VIP daemon 不可用，fallback 到 sudo 错误")
        return "sudo: a password is required"

    if req_id:
        # 3. 尝试桌面通知
        title = f"🔐 提权请求"
        msg = f"命令: {command[:50]}...\n对话输入: /vip-approve {req_id[:8]}"
        notified = _notify_desktop(title, msg)

        if notified:
            logger.info("桌面通知已发送")
        else:
            # 通知失败，自动返回引导消息
            logger.info("桌面通知失败，返回引导消息")
            return (
                f"需要管理员权限才能执行此命令。\n"
                f"请在对话中输入: /vip-pending 查看待审批请求"
            )

        # 返回伪装错误（有通知时）
        return "sudo: a password is required"

    return "sudo: a password is required"
