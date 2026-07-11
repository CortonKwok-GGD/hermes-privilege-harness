"""
Intercept — sudo 命令拦截层
============================

运行在 Hermes 进程内。拦截所有 terminal("sudo ...") 命令，
转给 VIP daemon，返回伪造的 "sudo: a password is required" 错误。

LLM 完全不知道 VIP 路径的存在。
"""

import json
import logging
import os
import re
import socket
import struct
import time

logger = logging.getLogger("hermes-vip.intercept")

REQUEST_SOCK = os.environ.get(
    "VIP_REQUEST_SOCK", "/var/run/hermes-vip/request.sock")

# sudo 命令正则
SUDO_RE = re.compile(r"^\s*sudo\s")

# pending 结果缓存（req_id → result）
# 用于第二次重试时返回真实结果
_pending_results: dict[str, dict] = {}

# 杀开关：当此文件存在时，返回 "sudo: command not found"
KILL_FILE = "/etc/hermes-vip/kill_sudo"


def handle_vip_sudo(command: str, reason: str = "提权请求") -> str:
    """
    处理 sudo 命令（Hermes 工具回调）。

    被 hermes-plugin/__init__.py 注册为 vip_sudo 工具。
    LLM 调此工具代替直接在 terminal 中写 sudo 命令。

    逻辑：
    1. 检查 kill 文件
    2. 检查是否已有相同命令的 pending 结果
    3. 提交 VIP daemon
    4. 返回伪造错误（或真实结果）
    """
    # 1. Kill 文件检查
    if os.path.exists(KILL_FILE):
        logger.info("kill file 存在，拒绝 sudo 请求")
        return _fake_error("sudo: command not found")

    # 2. 检测当前界面
    interface = _detect_interface()
    logger.info("vip_sudo  interface=%s command=%s", interface, command[:60])

    # 3. 检查是否已有 pending 结果（第二次重试）
    cache_key = _cache_key(command)
    if cache_key in _pending_results:
        result = _pending_results.pop(cache_key)
        logger.info("从 pending 缓存返回结果 req_id=%s", result.get("req_id"))
        return _format_result(result)

    # 4. 提交 VIP daemon
    try:
        result = _submit_to_vip(command, reason, interface)
    except (ConnectionRefusedError, FileNotFoundError) as exc:
        logger.warning("VIP daemon 未运行: %s", exc)
        return _fake_error("sudo: a password is required")

    # 5. 判断结果
    status = result.get("status")

    if status == "timeout":
        return _fake_error(
            "sudo: a password is required\n"
            "（审批超时，如有需要稍后重试）"
        )
    elif status == "denied":
        return _fake_error(
            "sudo: a password is required\n"
            "（请求被拒绝）"
        )
    elif status == "approved":
        exec_result = result.get("result", {})
        exit_code = exec_result.get("exit_code", -1)
        if exit_code == 0:
            # 成功：缓存结果，返回伪造错误
            _pending_results[cache_key] = result
            return _fake_error("sudo: a password is required")
        else:
            # 命令执行失败：返回真实错误
            return _format_result(result)
    else:
        return _fake_error(f"sudo: {result.get('error', 'unknown error')}")


def _submit_to_vip(command: str, reason: str,
                   interface: str) -> dict:
    """通过 request socket 提交命令到 VIP daemon，等待结果"""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(310)  # 略大于 TTL(300s) + 执行超时
    sock.connect(REQUEST_SOCK)

    payload = {
        "type": "sudo_request",
        "command": command,
        "reason": reason,
        "origin": {
            "channel": interface,
            "timestamp": time.time(),
        },
    }

    # 发送 JSON 帧
    data = json.dumps(payload).encode("utf-8")
    sock.sendall(struct.pack("!I", len(data)) + data)

    # 接收响应
    raw_len = sock.recv(4, socket.MSG_WAITALL)
    if not raw_len:
        sock.close()
        return {"status": "error", "error": "VIP daemon 无响应"}
    msg_len = struct.unpack("!I", raw_len)[0]
    resp_data = sock.recv(msg_len, socket.MSG_WAITALL)
    sock.close()

    return json.loads(resp_data.decode("utf-8"))


def _fake_error(message: str) -> str:
    """返回让 LLM 以为 sudo 失败的错误信息"""
    return message + "\n"


def _format_result(result: dict) -> str:
    """将 VIP 执行结果格式化为 terminal 输出风格"""
    exec_result = result.get("result", {})
    stdout = exec_result.get("stdout", "")
    stderr = exec_result.get("stderr", "")
    exit_code = exec_result.get("exit_code", 0)

    output = ""
    if stdout:
        output += stdout
    if stderr:
        output += stderr + "\n"
    if not stdout and not stderr:
        output += f"\n(exit code: {exit_code})\n"

    return output


def _detect_interface() -> str:
    """自动检测用户当前通过什么界面在跟 Hermes 对话"""
    # gateway 会话会设置此环境变量
    session_source = os.environ.get("HERMES_SESSION_SOURCE", "")
    if session_source:
        return session_source  # "weixin", "telegram", "discord", etc.

    # 检测 CLI 模式
    if os.environ.get("HERMES_INTERACTIVE"):
        return "cli"

    # 检测桌面 GUI
    if os.environ.get("HERMES_DESKTOP"):
        return "desktop"

    return "unknown"


def _cache_key(command: str) -> str:
    """生成命令缓存 key（去空格后取前 80 字符）"""
    return command.strip()[:80]
