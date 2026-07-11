"""
CLI & Desktop 审批通知
"""

import logging
import os
import platform
import subprocess
import sys

logger = logging.getLogger("vipd.connector.cli")

# 当前登录用户（daemon 以 root 运行，从 SUDO_USER 或 login 获取）
_REAL_USER = os.environ.get("SUDO_USER") or "admin"
_REAL_UID = os.environ.get("SUDO_UID") or "1000"
_DISPLAY = os.environ.get("DISPLAY", ":0")
_DBUS_BUS = f"/run/user/{_REAL_UID}/bus"


def _notify(title: str, msg: str):
    """发送桌面通知（通过真实用户身份）"""
    try:
        env = {
            "DISPLAY": _DISPLAY,
            "DBUS_SESSION_BUS_ADDRESS": f"unix:path={_DBUS_BUS}",
        }
        if platform.system() == "Linux":
            subprocess.run(
                ["sudo", "-u", _REAL_USER, "notify-send", title, msg, "-i", "dialog-password"],
                timeout=3, stderr=subprocess.DEVNULL, env=env,
            )
    except Exception:
        pass  # 通知失败不阻塞


def send_approval(data: dict) -> None:
    req_id = data.get("req_id", "???")
    command = data.get("command", "")
    reason = data.get("reason", "")
    expiry = data.get("expires_at_str", "")

    # 桌面通知
    _notify(f"🔐 提权请求 #{req_id[:8]}", f"命令: {command[:50]}")

    # 终端审批卡
    print()
    print("┌" + "─" * 58 + "┐")
    print(f"│  🔐 VIP 提权请求 #{req_id}" + " " * 30 + "│")
    print("├" + "─" * 58 + "┤")
    print(f"│  命令：{command[:52]}" + " " * max(0, 56 - len(command[:52])) + "│")
    print(f"│  原因：{reason[:52]}" + " " * max(0, 56 - len(reason[:52])) + "│")
    print(f"│  过期：{expiry}" + " " * 48 + "│")
    print("├" + "─" * 58 + "┤")
    print(f"│  /vip-approve {req_id}" + " " * (54 - 14 - len(req_id)) + "│")
    print(f"│  /vip-deny {req_id}" + " " * (54 - 12 - len(req_id)) + "│")
    print("└" + "─" * 58 + "┘")
    sys.stdout.flush()
