# DEPRECATED — connectors unused in v1.0 (sudo_execute replaces approval queue). See WBS.md.
"""
Hermes Gateway Connector — 复用 Hermes 现有网关通道

连接器运行在 Hermes 进程内（由 plugin 管理），通过 control socket
将用户的审批响应发送给 VIP daemon。

此连接器本身不直接发消息——它依赖 Hermes 网关的现有消息通道。
Plugin 的 gateway_handler 收到用户的 /vip-approve 后，
通过此连接器将批准发到 VIP 的 control socket。
"""

import json
import logging
import os
import socket
import struct

logger = logging.getLogger("vipd.connector.hermes_gateway")

CONTROL_SOCK = os.environ.get(
    "VIP_CONTROL_SOCK", "/var/run/hermes-vip/control.sock")


def send_approval(approval_data: dict) -> None:
    """
    发送审批通知到用户（通过 Hermes 网关的已有通道）。

    注意：真正的消息发送由 Hermes Plugin 的 gateway_handler 负责。
    这里仅作为连接器注册到 VIP daemon 的占位——表示激活态。
    """
    logger.debug("hermes_gateway 连接器存活（消息推送由 Hermes 网关处理）")


def send_response(req_id: str, action: str, verified_by: str = "") -> dict:
    """
    通过 control socket 发送审批响应到 VIP daemon。

    由 Hermes Plugin 的 gateway_handler 调用。

    Returns: {"status": "ok" | "not_found"}
    """
    payload = {
        "type": "approval_response",
        "req_id": req_id,
        "action": action,
        "connector": "hermes_gateway",
        "verified_by": verified_by,
        "timestamp": __import__("time").time(),
    }

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(CONTROL_SOCK)

        # 发送 JSON 帧
        data = json.dumps(payload).encode("utf-8")
        sock.sendall(struct.pack("!I", len(data)) + data)

        # 接收响应
        raw_len = sock.recv(4, socket.MSG_WAITALL)
        if raw_len:
            msg_len = struct.unpack("!I", raw_len)[0]
            resp_data = sock.recv(msg_len, socket.MSG_WAITALL)
            sock.close()
            return json.loads(resp_data.decode("utf-8"))

        sock.close()
        return {"status": "error", "error": "无响应"}
    except (socket.error, ConnectionRefusedError) as exc:
        logger.error("control socket 连接失败: %s", exc)
        return {"status": "error", "error": str(exc)}
