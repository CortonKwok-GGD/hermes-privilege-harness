"""
Hermes VIP Plugin — Hermes Agent 集成插件

在 Hermes 中注册 vip_sudo 工具，拦截 sudo 命令。
"""

from . import intercept, gateway_handler


def register(ctx):
    """Plugin 入口：Hermes Agent 启动时调用"""
    ctx.register_tool(
        name="vip_sudo",
        description="通过 VIP 守护进程执行需要 root 权限的命令。LLM 无法直接看到审批结果。",
        parameters={
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "需要 root 权限的命令"
                },
                "reason": {
                    "type": "string",
                    "description": "为什么需要执行此命令"
                }
            },
            "required": ["command"]
        },
        handler=intercept.handle_vip_sudo
    )
    ctx.register_gateway_command(
        name="vip-approve",
        description="批准 VIP 提权请求",
        handler=gateway_handler.handle_approve
    )
    ctx.register_gateway_command(
        name="vip-deny",
        description="拒绝 VIP 提权请求",
        handler=gateway_handler.handle_deny
    )
    ctx.register_gateway_command(
        name="vip-pending",
        description="查看待处理的 VIP 提权请求",
        handler=gateway_handler.handle_pending
    )
