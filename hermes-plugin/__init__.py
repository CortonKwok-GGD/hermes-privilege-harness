"""Hermes Privilege Harness — Passive VIP Plugin.

Architecture: Hermes handles approval, we handle execution.
"""

import logging
import re
from . import guard

logger = logging.getLogger("hermes-vip.plugin")


def _inject_git_push_pattern():
    """Inject git push into Hermes native dangerous-pattern detection."""
    try:
        from tools.approval import DANGEROUS_PATTERNS, DANGEROUS_PATTERNS_COMPILED
        pattern = (r'(?:^|[;&|&(])\s*git\s+push\b', "git push (requires approval)")
        if pattern not in DANGEROUS_PATTERNS:
            DANGEROUS_PATTERNS.append(pattern)
            DANGEROUS_PATTERNS_COMPILED.append(
                (re.compile(pattern[0], re.IGNORECASE), pattern[1])
            )
            logger.info("injected git push into Hermes DANGEROUS_PATTERNS")
    except Exception as e:
        logger.warning("failed to inject git push pattern: %s", e)


def _patch_approval_display():
    """Monkey-patch _run_approval_gate so vip_sudo cards show the real command."""
    try:
        from tools.approval import _run_approval_gate as _original
        import functools

        @functools.wraps(_original)
        def _patched(*, display_target, description, **kw):
            if description and description.startswith("sudo:"):
                display_target = description
            return _original(
                display_target=display_target,
                description=description,
                **kw,
            )

        import tools.approval
        tools.approval._run_approval_gate = _patched
        logger.info("patched _run_approval_gate for vip_sudo display")
    except Exception as e:
        logger.warning("failed to patch approval display: %s", e)


def register(ctx):
    # Enhance Hermes native detection + improve vip_sudo card display
    _inject_git_push_pattern()
    _patch_approval_display()

    # pre_tool_call — only intercept vip_sudo for native approval card
    ctx.register_hook("pre_tool_call", _hook)

    # vip_sudo — the ONLY privileged tool
    ctx.register_tool(
        name="vip_sudo",
        toolset="terminal",
        description=(
            "Execute commands as root via a secure privilege daemon. "
            "Hermes will prompt for approval before execution."
        ),
        schema={
            "name": "vip_sudo",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "Shell command to execute as root",
                    },
                    "reason": {
                        "type": "string",
                        "description": "Why root is needed",
                    },
                },
                "required": ["command"],
            },
        },
        handler=lambda args, **kw: guard.vip_sudo(
            args.get("command", "") if isinstance(args, dict) else str(args),
            args.get("reason", "") if isinstance(args, dict) else "",
        ),
    )

    logger.info("hermes-privilege-harness plugin ready (passive + git push)")


def _hook(tool_name, args, **kwargs):
    return guard.check(tool_name, args if isinstance(args, dict) else {})
