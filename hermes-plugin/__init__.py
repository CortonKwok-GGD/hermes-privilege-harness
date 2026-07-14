"""Hermes VIP plugin - native approval + daemon + git push injection"""

import logging
import re
from . import guard

logger = logging.getLogger("hermes-vip.plugin")


def _inject_git_push_pattern():
    """Inject git push into Hermes native dangerous-pattern detection."""
    try:
        from tools.approval import DANGEROUS_PATTERNS, DANGEROUS_PATTERNS_COMPILED
        pattern = (r'\bgit\s+push\b', "git push (requires approval)")
        if pattern not in DANGEROUS_PATTERNS:
            DANGEROUS_PATTERNS.append(pattern)
            DANGEROUS_PATTERNS_COMPILED.append(
                (re.compile(pattern[0], re.IGNORECASE), pattern[1])
            )
            logger.info("injected git push into Hermes DANGEROUS_PATTERNS")
    except Exception as e:
        logger.warning("failed to inject git push pattern: %s", e)


def register(ctx):
    # ── 0. 注入 git push 到 Hermes 原生危险命令检测 ──
    _inject_git_push_pattern()

    # ── 1. pre_tool_call：拦截 sudo + 触发原生审批卡片 ──
    ctx.register_hook("pre_tool_call", _hook)

    # ── 2. vip_sudo：唯一提权工具 ──
    ctx.register_tool(
        name="vip_sudo",
        toolset="terminal",
        description=(
            "Execute privileged commands that require root access. "
            "This is the ONLY way to run commands with sudo/root privileges. "
            "After user approval, executes through a secure daemon."
        ),
        schema={
            "name": "vip_sudo",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "Shell command to execute with root privileges",
                    },
                    "reason": {
                        "type": "string",
                        "description": "Why this command needs root privileges",
                    },
                },
                "required": ["command"],
            },
        },
        handler=lambda args, **kw: guard.vip_sudo(
            args.get("command", "") if isinstance(args, dict) else str(args),
            args.get("reason", "") if isinstance(args, dict) else "",
        ),
        is_async=False,
    )

    # ── 3. Slash commands ──
    ctx.register_command(
        name="vip-pending",
        handler=lambda _args="": _handle_pending(),
        description="List pending privilege requests",
    )

    # ── 4. pre_llm_call：告诉 LLM 唯一提权路径 ──
    ctx.register_hook("pre_llm_call", _inject)
    logger.info("hermes-vip plugin ready")


def _hook(tool_name, args, **kwargs):
    """pre_tool_call: block sudo -> vip_sudo; vip_sudo -> native approval"""
    return guard.check(tool_name, args if isinstance(args, dict) else {})


def _inject(**kwargs):
    if kwargs.get("is_first_turn"):
        return {
            "context": (
                "[SYSTEM]: Sudo is NOT available via the terminal tool. "
                "For privileged commands, use vip_sudo. "
                "You will be prompted for approval."
            )
        }
    return None


def _handle_pending():
    """查看待审批请求"""
    import json, os, socket, struct
    cs = os.environ.get("VIP_CONTROL_SOCK", "/var/run/hermes-vip/control.sock")
    try:
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(5)
        s.connect(cs)
        d = json.dumps({"type": "list_pending"}).encode()
        s.sendall(struct.pack("!I", len(d)) + d)
        rl = s.recv(4)
        resp = json.loads(s.recv(struct.unpack("!I", rl)[0]).decode()) if rl else {}
        s.close()
    except Exception as exc:
        return f"VIP daemon unreachable: {exc}"

    pending = resp.get("pending", [])
    if not pending:
        return "No pending privilege requests."
    lines = ["Pending privilege requests:"]
    for item in pending:
        lines.append(f"  {item['req_id'][:14]}: {str(item.get('command',''))[:60]}")
    return "\n".join(lines)
