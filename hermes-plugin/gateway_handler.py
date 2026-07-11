"""
Gateway Handler — 网关命令处理器
=================================

处理用户通过网关发送的 /vip-approve /vip-deny /vip-pending 命令。
命令绕过 LLM，直接通过 control socket 发送到 VIP daemon。

Hermes 网关已有相同的 bypass 机制（/approve /deny 绕过 LLM），
/vip-* 命令同样由网关直接路由，不走 LLM。

Handler 签名（register_command 要求）:
    fn(raw_args: str) -> str | None
"""

import json
import logging
import os
import shlex
import socket
import struct
import time

logger = logging.getLogger("hermes-vip.gateway_handler")

CONTROL_SOCK = os.environ.get(
    "VIP_CONTROL_SOCK", "/var/run/hermes-vip/control.sock")


def handle_approve(args: str) -> str:
    """
    处理 /vip-approve <req_id>
    绕过 LLM，直接发批准到 VIP control socket
    """
    tokens = shlex.split(args) if args else []
    if not tokens:
        return (
            "用法: /vip-approve <req_id>\n"
            "查看待审批: /vip-pending"
        )

    req_id = tokens[0]

    result = _send_to_control_socket({
        "type": "approval_response",
        "req_id": req_id,
        "action": "approve",
        "connector": "hermes_gateway",
        "verified_by": "gateway_user",
        "timestamp": time.time(),
    })

    if result.get("status") == "ok":
        # 批准成功，等结果
        time.sleep(1)
        exec_result = _send_to_control_socket({
            "type": "get_result",
            "req_id": req_id,
        })
        if exec_result.get("status") == "approved":
            er = exec_result.get("result", {})
            stdout = er.get("stdout", "").strip()
            stderr = er.get("stderr", "").strip()
            exit_code = er.get("exit_code", -1)

            if exit_code == 0:
                if stdout:
                    return f"✅ 命令执行成功:\n{stdout[:2000]}"
                return f"✅ 命令执行成功 (exit=0)"
            else:
                error = stderr or f"exit code {exit_code}"
                return f"❌ 命令执行失败: {error[:500]}"
        else:
            return f"✅ 已批准请求 {req_id}（结果获取中，可稍后使用 vip_check 查看）"
    else:
        return f"❌ 批准失败: {result.get('error', '请求不存在或已处理')}"


def handle_deny(args: str) -> str:
    """
    处理 /vip-deny <req_id>
    绕过 LLM，直接发拒绝到 VIP control socket
    """
    tokens = shlex.split(args) if args else []
    if not tokens:
        return (
            "用法: /vip-deny <req_id>\n"
            "查看待审批: /vip-pending"
        )

    req_id = tokens[0]

    result = _send_to_control_socket({
        "type": "approval_response",
        "req_id": req_id,
        "action": "deny",
        "connector": "hermes_gateway",
        "verified_by": "gateway_user",
        "timestamp": time.time(),
    })

    if result.get("status") == "ok":
        return f"❌ 已拒绝请求 {req_id}"
    else:
        return f"⚠️ 拒绝失败: {result.get('error', '请求不存在或已处理')}"


def handle_pending(_args: str = "") -> str:
    """
    处理 /vip-pending — 列出所有待审批的提权请求
    通过 control socket 从 VIP daemon 拉取
    """
    try:
        pending = _list_pending()
    except Exception as exc:
        return f"无法获取待审列表: {exc}"

    if not pending:
        return "📭 没有待处理的提权请求"

    lines = ["📋 待审批的提权请求:\n"]
    for item in pending:
        req_id = item.get("req_id", "???")
        command = item.get("command", "")[:50]
        reason = item.get("reason", "")[:40]
        remaining = int(item.get("expires_at", 0) - time.time()) if item.get("expires_at") else 0

        lines.append(f"  #{req_id}")
        lines.append(f"    命令: {command}")
        if reason:
            lines.append(f"    原因: {reason}")
        lines.append(f"    剩余: {remaining}s" if remaining > 0 else "    过期: 即将超时")
        lines.append(f"    /vip-approve {req_id}  — 批准")
        lines.append(f"    /vip-deny {req_id}     — 拒绝")
        lines.append("")

    return "\n".join(lines)


# ── 内部方法 ──


def _send_to_control_socket(payload: dict) -> dict:
    """通过 control socket 发送消息到 VIP daemon"""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(CONTROL_SOCK)

        data = json.dumps(payload).encode("utf-8")
        sock.sendall(struct.pack("!I", len(data)) + data)

        raw_len = sock.recv(4, socket.MSG_WAITALL)
        if not raw_len:
            sock.close()
            return {"status": "error", "error": "VIP daemon 无响应"}
        msg_len = struct.unpack("!I", raw_len)[0]
        resp_data = sock.recv(msg_len, socket.MSG_WAITALL)
        sock.close()
        return json.loads(resp_data.decode("utf-8"))

    except (socket.error, ConnectionRefusedError, FileNotFoundError) as exc:
        logger.error("control socket 连接失败: %s", exc)
        return {"status": "error", "error": str(exc)}


def _list_pending() -> list[dict]:
    """从 VIP daemon 获取待审批列表"""
    result = _send_to_control_socket({
        "type": "list_pending",
    })
    return result.get("pending", [])
