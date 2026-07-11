"""
CLI / Desktop Connector — 终端和桌面审批通知
"""

import logging
import os
import platform
import subprocess
import sys

logger = logging.getLogger("vipd.connector.cli")


def _detect_ui_mode() -> str:
    if os.environ.get("HERMES_DESKTOP"):
        return "desktop"
    if os.environ.get("HERMES_INTERACTIVE"):
        return "cli"
    return "cli"


def _notify_desktop(title: str, message: str):
    """发送桌面通知（通过当前登录用户的 dbus）"""
    system = platform.system()
    try:
        # 获取登录用户的环境
        for uid in (os.getenv("SUDO_UID"), "1000"):
            if not uid:
                continue
            if system == "Linux":
                subprocess.run(
                    ["sudo", "-u", f"#{uid}", "notify-send",
                     title, message, "-i", "dialog-password"],
                    timeout=3, stderr=subprocess.DEVNULL,
                )
            elif system == "Darwin":
                subprocess.run(
                    ["sudo", "-u", f"#{uid}", "osascript", "-e",
                     f'display notification "{message}" with title "{title}"'],
                    timeout=3, stderr=subprocess.DEVNULL,
                )
            break
    except Exception:
        pass


def send_approval(approval_data: dict) -> None:
    req_id = approval_data.get("req_id", "???")
    command = approval_data.get("command", "")
    reason = approval_data.get("reason", "")
    expiry = approval_data.get("expires_at_str", "")
    ui_mode = _detect_ui_mode()

    if ui_mode == "desktop":
        _notify_desktop(
            f"🔐 提权请求 #{req_id}",
            f"命令: {command[:60]}\n原因: {reason[:40]}\n对话: /vip-approve {req_id}",
        )

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
    print("├" + "─" * 58 + "┤")
    print("│  在对话中直接输入斜杠命令即可审批              │")
    print("└" + "─" * 58 + "┘")
    sys.stdout.flush()
