"""
Intercept — terminal 命令先走 bwrap 沙箱，失败才走 VIP
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
    处理 terminal 命令：先试 bwrap，失败走 VIP。
    
    Returns: {"action": "return_immediately", "result": str}
    """
    is_sudo = bool(SUDO_RE.match(command))

    # 非 sudo 命令先试 bwrap
    if not is_sudo and os.path.exists(BWRAP):
        try:
            result = subprocess.run(
                [BWRAP, "/bin/bash", "-c", command],
                capture_output=True, text=True, timeout=30,
            )
            if result.returncode == 0:
                return {"action": "return_immediately", "result": result.stdout}
            # bwrap 失败了（可能没权限），fallthrough 到 VIP
        except Exception:
            pass

    # sudo 或 bwrap 失败 → 走 VIP
    if is_sudo or os.path.exists(BWRAP):
        return _vip_flow(command, reason or "提权请求")

    # 没有 bwrap，直接放行
    return None


def _vip_flow(command: str, reason: str) -> dict:
    """提交 VIP daemon 并等待审批"""
    # Kill 文件检查
    if os.path.exists(KILL_FILE):
        return {"action": "return_immediately",
                "result": "sudo: command not found"}

    # 连接 VIP daemon
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(10)
    try:
        sock.connect(REQUEST_SOCK)
    except (FileNotFoundError, ConnectionRefusedError) as exc:
        logger.warning("VIP daemon 未运行: %s", exc)
        return {"action": "return_immediately",
                "result": "需要管理员权限，请在对话中输入 /vip-pending"}

    # 提交请求
    req = {
        "type": "sudo_request",
        "command": command,
        "reason": reason,
        "origin": {"channel": "cli", "timestamp": time.time()},
    }
    payload = json.dumps(req).encode()
    sock.sendall(struct.pack("!I", len(payload)) + payload)

    # 收 pending 响应（立即返回）
    raw_len = sock.recv(4, socket.MSG_WAITALL)
    if raw_len:
        resp = json.loads(sock.recv(struct.unpack("!I", raw_len)[0], socket.MSG_WAITALL))
        req_id = resp.get("req_id", "")
        if req_id:
            # 桌面通知
            _notify(f"🔐 提权请求", f"命令: {command[:50]}")

            # 等审批结果
            raw_len = sock.recv(4, socket.MSG_WAITALL)
            if raw_len:
                result = json.loads(sock.recv(struct.unpack("!I", raw_len)[0], socket.MSG_WAITALL))
                sock.close()
                if result.get("status") == "approved":
                    exec_r = result.get("result", {})
                    return {"action": "return_immediately",
                            "result": exec_r.get("stdout", "")}
                return {"action": "return_immediately",
                        "result": "命令被拒绝"}
            
            return {"action": "return_immediately",
                    "result": "审批超时，请输入 /vip-pending 查看"}

    sock.close()
    return {"action": "return_immediately",
            "result": "需要管理员权限，请输入 /vip-pending"}


def _notify(title: str, msg: str):
    """发送桌面通知"""
    try:
        subprocess.run(["notify-send", title, msg, "-i", "dialog-password"],
                       timeout=3, stderr=subprocess.DEVNULL)
    except Exception:
        pass


# 保留旧接口兼容
handle_vip_sudo = lambda cmd, reason="": _vip_flow(cmd, reason)
