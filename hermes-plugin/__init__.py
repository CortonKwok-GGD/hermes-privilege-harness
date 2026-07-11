"""
Hermes VIP Plugin — 三层安全防护
1. 所有 terminal 命令先走 bwrap 沙箱
2. 失败后自动转入 VIP 审批
3. vip_sudo 工具作为显式提权通道
"""

import logging
from . import intercept

logger = logging.getLogger("hermes-vip.plugin")


def register(ctx):
    # ── 1. 拦截所有 terminal 调用 ──
    ctx.register_hook("pre_tool_call", _intercept_terminal)

    # ── 2. vip_sudo 工具 ──
    ctx.register_tool(
        name="vip_sudo",
        toolset="terminal",
        description="执行需要管理员权限的命令。普通 terminal 被沙箱限制时用此工具。",
        schema={
            "name": "vip_sudo",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "命令"},
                    "reason": {"type": "string", "description": "原因"},
                },
                "required": ["command"],
            },
        },
        handler=lambda cmd, reason="", **kw: intercept._vip_flow(cmd, reason),
        is_async=False,
    )

    # ── 3. 斜杠命令（绕过 LLM）──
    from . import gateway_handler
    for cmd, handler in [
        ("vip-approve", gateway_handler.handle_approve),
        ("vip-deny", gateway_handler.handle_deny),
        ("vip-pending", gateway_handler.handle_pending),
    ]:
        ctx.register_command(name=cmd, handler=handler, description=cmd)

    # ── 4. pre_llm_call：注入 sandbox 提示 ──
    ctx.register_hook("pre_llm_call", _sandbox_hint)
    logger.info("hermes-vip plugin ready")


def _intercept_terminal(tool_name, args, **kwargs):
    """拦截所有 terminal 命令，先试 bwrap"""
    if tool_name != "terminal":
        return None
    command = args.get("command", "")
    reason = args.get("reason", "")
    result = intercept.handle_terminal(command, reason)
    if result:
        result.setdefault("action", "return_immediately")
        return result
    return None


def _sandbox_hint(**kwargs):
    if kwargs.get("is_first_turn"):
        return {"context": (
            "[SYSTEM]: 你运行在安全沙箱中，不能直接修改系统。"
            "请使用 vip_sudo 工具提交提权请求。"
        )}
    return None
