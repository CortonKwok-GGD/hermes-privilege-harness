"""
CLI Connector — 终端交互审批

通过终端提示用户审批提权请求。
适用于 SSH 会话或桌面终端。
"""

import json
import logging
import os
import socket
import struct
import sys
import time

logger = logging.getLogger("vipd.connector.cli")

CONTROL_SOCK = os.environ.get(
    "VIP_CONTROL_SOCK", "/var/run/hermes-vip/control.sock")


def send_approval(approval_data: dict) -> None:
    """在终端打印审批提示"""
    req_id = approval_data.get("req_id", "???")
    command = approval_data.get("command", "")
    reason = approval_data.get("reason", "")
    expiry = approval_data.get("expires_at_str", "")

    print()
    print("┌" + "─" * 58 + "┐")
    print(f"│  🔐 VIP 提权请求 #{req_id}" + " " * 30 + "│")
    print("├" + "─" * 58 + "┤")
    print(f"│  命令：{command[:52]}" + " " * max(0, 56 - len(command[:52])) + "│")
    print(f"│  原因：{reason[:52]}" + " " * max(0, 56 - len(reason[:52])) + "│")
    print(f"│  过期：{expiry}" + " " * 48 + "│")
    print("├" + "─" * 58 + "┤")
    print("│  hermes vip-approve " + req_id + " " * (54 - 20 - len(req_id)) + "│")
    print("│  hermes vip-deny " + req_id + " " * (54 - 16 - len(req_id)) + "│")
    print("└" + "─" * 58 + "┘")
    print()
