"""
Hermes VIP Plugin — Hermes Agent 集成插件

在 Hermes 中注册：
1. vip_sudo 工具 — LLM 调用来提交提权请求
2. /vip-approve 命令 — 绕过 LLM 批准请求
3. /vip-deny 命令 — 绕过 LLM 拒绝请求
4. /vip-pending 命令 — 查看待审列表
"""

import json
import logging

from . import intercept, gateway_handler

logger = logging.getLogger("hermes-vip.plugin")


def register(ctx):
    """Plugin 入口：Hermes Agent 启动时调用"""

    # ── 1. 注册 vip_sudo 工具 ──
    # LLM 调此工具代替 terminal("sudo ...")
    ctx.register_tool(
        name="vip_sudo",
        toolset="terminal",  # 挂在 terminal toolset 下
        description=(
            "通过 VIP 守护进程执行需要 root 权限的命令。"
            "LLM 看不到审批结果，命令由 root 进程执行。"
            "当 LLM 需要 sudo 时调用此工具替代 terminal。"
        ),
        schema={
            "name": "vip_sudo",
            "description": "执行需要 root 权限的命令（经 VIP 审批）",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "需要 root 权限执行的 shell 命令"
                    },
                    "reason": {
                        "type": "string",
                        "description": "为什么需要执行此命令（显示在审批卡上）"
                    }
                },
                "required": ["command"]
            }
        },
        handler=_handle_vip_sudo,
        is_async=False,
    )
    logger.info("registered tool: vip_sudo")

    # ── 2. 注册网关斜杠命令 ──
    # 这些命令绕过 LLM，由网关直接路由到 handler
    # handler 签名: fn(raw_args: str) -> str | None

    ctx.register_command(
        name="vip-approve",
        handler=lambda args, ctx={}: gateway_handler.handle_approve(args, ctx),
        description="批准 VIP 提权请求",
        args_hint="<req_id>",
    )
    logger.info("registered command: /vip-approve")

    ctx.register_command(
        name="vip-deny",
        handler=lambda args, ctx={}: gateway_handler.handle_deny(args, ctx),
        description="拒绝 VIP 提权请求",
        args_hint="<req_id>",
    )
    logger.info("registered command: /vip-deny")

    ctx.register_command(
        name="vip-pending",
        handler=lambda args, ctx={}: gateway_handler.handle_pending(args, ctx),
        description="查看待处理的 VIP 提权请求",
    )
    logger.info("registered command: /vip-pending")

    # ── 3. 预留给 CLI 子命令 ──
    # 未来可注册 hermes vip 子命令
    # ctx.register_cli_command(
    #     name="vip",
    #     help="VIP daemon 管理命令",
    #     setup_fn=_setup_vip_subparser,
    # )


def _handle_vip_sudo(command: str, reason: str = "", **kwargs) -> str:
    """vip_sudo 工具的处理函数（同步，返回字符串）"""
    if not reason:
        reason = "提权请求"
    result = intercept.handle_vip_sudo(command, reason)
    return result
