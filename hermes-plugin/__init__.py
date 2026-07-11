"""
Hermes VIP Plugin — 三层安全防护

1. pre_llm_call: 首轮注入 sandbox 提示（强引导）
2. pre_tool_call: 拦截 terminal sudo 命令
3. vip_sudo 工具：显式提权通道
"""

import logging
import re

from . import intercept, gateway_handler

logger = logging.getLogger("hermes-vip.plugin")

SUDO_RE = re.compile(r"^\s*sudo\s")

# 首轮 sandbox 提示
SANDBOX_INSTRUCTION = (
    "[SYSTEM]: 你运行在安全沙箱中，不能直接修改系统。\n"
    "如果需要执行需要管理员权限的操作（安装软件、修改配置等），"
    "请使用 vip_sudo 工具提交提权请求，等待用户批准后执行。"
)


def register(ctx):
    # ── 1. pre_llm_call：首轮注入 sandbox 提示 ──
    ctx.register_hook("pre_llm_call", _inject_sandbox_hint)

    # ── 2. pre_tool_call：拦截 terminal sudo ──
    ctx.register_hook("pre_tool_call", _intercept_sudo)

    # ── 3. vip_sudo 工具 ──
    ctx.register_tool(
        name="vip_sudo",
        toolset="terminal",
        description=(
            "执行需要管理员权限的命令（安装/卸载软件、修改系统配置等）。"
            "普通 terminal 没有权限时，用此工具提交审批。"
        ),
        schema={
            "name": "vip_sudo",
            "description": "提交管理员权限请求",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "需要管理员权限执行的命令"
                    },
                    "reason": {
                        "type": "string",
                        "description": "为什么需要执行此命令"
                    }
                },
                "required": ["command"]
            }
        },
        handler=_handle_vip_sudo,
        is_async=False,
    )
    logger.info("vip_sudo registered")

    # ── 4. 斜杠命令（绕过 LLM）──
    ctx.register_command(
        name="vip-approve",
        handler=gateway_handler.handle_approve,
        description="批准 VIP 提权请求",
        args_hint="<req_id>",
    )
    ctx.register_command(
        name="vip-deny",
        handler=gateway_handler.handle_deny,
        description="拒绝 VIP 提权请求",
        args_hint="<req_id>",
    )
    ctx.register_command(
        name="vip-pending",
        handler=gateway_handler.handle_pending,
        description="查看待处理的 VIP 提权请求",
    )
    logger.info("hermes-vip plugin ready")


def _inject_sandbox_hint(**kwargs):
    """pre_llm_call：首轮对话注入 sandbox 提示"""
    is_first = kwargs.get("is_first_turn", False)
    if is_first:
        logger.debug("injecting sandbox hint")
        return {"context": SANDBOX_INSTRUCTION}
    return None


def _intercept_sudo(tool_name, args, **kwargs):
    """pre_tool_call：拦截 terminal sudo"""
    if tool_name != "terminal":
        return None
    command = args.get("command", "")
    if not SUDO_RE.match(command):
        return None
    logger.info("intercepted sudo: %s", command[:60])
    reason = args.get("reason", "提权请求")
    result = intercept.handle_vip_sudo(command, reason)
    return {"action": "return_immediately", "result": result}


def _handle_vip_sudo(command: str, reason: str = "", **kwargs) -> str:
    if not reason:
        reason = "提权请求"
    return intercept.handle_vip_sudo(command, reason)
