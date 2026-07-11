"""
Gateway Handler — 网关命令处理器
=================================

处理用户通过网关发送的 /vip-approve /vip-deny /vip-pending 命令。
命令绕过 LLM，直接通过 control socket 发送到 VIP daemon。

Hermes 网关已有类似的 bypass 机制（/approve /deny 绕过 LLM），
这里复用同样的架构。
"""

import json
import logging
import os
import shlex

from .connectors.hermes_gateway import send_response as _send_to_vip

logger = logging.getLogger("hermes-vip.gateway_handler")


def handle_approve(args: str, context: dict) -> str:
    """
    处理 /vip-approve <req_id>

    命令绕过 LLM，由 Hermes 网关直接路由到这里。
    将批准信息发送到 VIP daemon 的 control socket。
    """
    tokens = shlex.split(args) if args else []
    if not tokens:
        return "用法: /vip-approve <req_id>\n查看待审: /vip-pending"

    req_id = tokens[0]
    verified_by = _get_verified_by(context)

    result = _send_to_vip(req_id, "approve", verified_by)

    if result.get("status") == "ok":
        return f"✅ 已批准请求 {req_id}"
    else:
        return f"❌ 批准失败: {result.get('error', '请求不存在或已处理')}"


def handle_deny(args: str, context: dict) -> str:
    """
    处理 /vip-deny <req_id>
    """
    tokens = shlex.split(args) if args else []
    if not tokens:
        return "用法: /vip-deny <req_id>\n查看待审: /vip-pending"

    req_id = tokens[0]
    verified_by = _get_verified_by(context)

    result = _send_to_vip(req_id, "deny", verified_by)

    if result.get("status") == "ok":
        return f"❌ 已拒绝请求 {req_id}"
    else:
        return f"⚠️ 拒绝失败: {result.get('error', '请求不存在或已处理')}"


def handle_pending(args: str, context: dict) -> str:
    """
    处理 /vip-pending — 列出所有待审批的提权请求
    """
    try:
        pending = _list_pending_from_vip()
    except Exception as exc:
        return f"无法获取待审列表: {exc}"

    if not pending:
        return "📭 没有待处理的提权请求"

    lines = ["📋 待审批的提权请求:\n"]
    for item in pending:
        req_id = item.get("req_id", "???")
        command = item.get("command", "")[:50]
        reason = item.get("reason", "")[:40]
        created = item.get("created_at", 0)
        expires = item.get("expires_at", 0)
        remaining = int(expires - __import__("time").time()) if expires else 0

        lines.append(f"  #{req_id}")
        lines.append(f"    命令: {command}")
        if reason:
            lines.append(f"    原因: {reason}")
        lines.append(f"    剩余: {remaining}s")
        lines.append(f"    /vip-approve {req_id}  — 批准")
        lines.append(f"    /vip-deny {req_id}     — 拒绝")
        lines.append("")

    return "\n".join(lines)


def _get_verified_by(context: dict) -> str:
    """从上下文提取用户标识"""
    platform = context.get("platform", "unknown")
    user_id = context.get("user_id", "")
    return f"{platform}:{user_id}" if user_id else platform


def _list_pending_from_vip() -> list[dict]:
    """通过 control socket 查询待审列表"""
    import socket
    import struct

    control_sock = os.environ.get(
        "VIP_CONTROL_SOCK", "/var/run/hermes-vip/control.sock")

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect(control_sock)

    payload = {"type": "list_pending"}
    data = json.dumps(payload).encode("utf-8")
    sock.sendall(struct.pack("!I", len(data)) + data)

    raw_len = sock.recv(4, socket.MSG_WAITALL)
    if not raw_len:
        sock.close()
        return []
    msg_len = struct.unpack("!I", raw_len)[0]
    resp_data = sock.recv(msg_len, socket.MSG_WAITALL)
    sock.close()

    result = json.loads(resp_data.decode("utf-8"))
    return result.get("pending", [])
