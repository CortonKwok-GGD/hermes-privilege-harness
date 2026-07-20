"""Hermes VIP plugin — sandbox isolation + privilege gate v8.0"""

import logging
import re
import subprocess
from . import guard
from . import sandbox

logger = logging.getLogger("hermes-vip.plugin")


def _inject_git_push_pattern():
    try:
        from tools.approval import DANGEROUS_PATTERNS, DANGEROUS_PATTERNS_COMPILED
        pattern = (r'(?:^|[;&|&(])\\s*git\\s+push\\b', "git push (requires approval)")
        if pattern not in DANGEROUS_PATTERNS:
            DANGEROUS_PATTERNS.append(pattern)
            DANGEROUS_PATTERNS_COMPILED.append(
                (re.compile(pattern[0], re.IGNORECASE), pattern[1])
            )
            logger.info("injected git push into DANGEROUS_PATTERNS")
    except Exception as e:
        logger.warning("failed to inject git push pattern: %s", e)


def _patch_approval_display():
    try:
        from tools.approval import _run_approval_gate as _original
        import functools

        @functools.wraps(_original)
        def _patched(*, display_target, description, **kw):
            if description and description.startswith("sudo:"):
                display_target = description
            return _original(display_target=display_target, description=description, **kw)

        import tools.approval
        tools.approval._run_approval_gate = _patched
        logger.info("patched _run_approval_gate for vip_sudo display")
    except Exception as e:
        logger.warning("failed to patch approval display: %s", e)


def register(ctx):
    _inject_git_push_pattern()
    _patch_approval_display()

    # ── pre_tool_call hook ──
    ctx.register_hook("pre_tool_call", _hook)

    # ── vip_sudo tool (conditional on config) ──
    _register_vip_sudo(ctx)

    # ── Slash commands ──
    ctx.register_command(
        name="vipsandbox",
        handler=lambda _args="": _handle_vipsandbox(_args),
        description="Toggle sandbox on/off, net on/off, or show status",
    )
    ctx.register_command(
        name="vipsudo",
        handler=lambda _args="": _handle_vipsudo(_args),
        description="Toggle vip_sudo on/off or show status",
    )
    ctx.register_command(
        name="vipdaemon",
        handler=lambda _args="": _handle_vipdaemon(_args),
        description="Show VIP daemon status",
    )

    # ── pre_llm_call: tell LLM about sandbox ──
    ctx.register_hook("pre_llm_call", _inject)
    logger.info("hermes-vip plugin registered")
    # Apply network state from config on session start
    sandbox.apply_network_state()
    sandbox.apply_mount_permissions()


def _register_vip_sudo(ctx):
    """Register vip_sudo tool if enabled in config."""
    if not sandbox.vip_sudo_enabled():
        logger.info("vip_sudo disabled by config — tool not registered")
        return

    ctx.register_tool(
        name="vip_sudo",
        toolset="terminal",
        description=(
            "Execute privileged commands that require root access. "
            "Also use to access files/directories outside the sandbox boundary. "
            "This is the ONLY way to run commands with sudo/root privileges "
            "and the ONLY way to read files outside the sandbox. "
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
                        "description": "Why this command needs to escape the sandbox",
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
    logger.info("vip_sudo tool registered")


def _hook(tool_name, args, **kwargs):
    """pre_tool_call: delegate to guard.check()"""
    return guard.check(tool_name, args if isinstance(args, dict) else {})


def _inject(**kwargs):
    if kwargs.get("is_first_turn"):
        sb_on = sandbox.sandbox_enabled()
        vs_on = sandbox.vip_sudo_enabled()
        net_on = sandbox.network_enabled()
        if sb_on and vs_on:
            msg = (
                "[SYSTEM]: You are in a sandbox (bwrap). "
                "Terminal handles files, network, scripts — no approval needed. "
                "vip_sudo is the only tool that requires approval."
            )
            if not net_on:
                msg += " Network is isolated. Ask user for /vipsandbox net on if needed."
        elif sb_on and not vs_on:
            msg = (
                "[SYSTEM]: You are in a sandbox (bwrap). "
                "Terminal handles files, network, scripts — no approval needed. "
                "vip_sudo is disabled — ask user for /vipsudo on if needed."
            )
        elif not sb_on and vs_on:
            msg = (
                "[SYSTEM]: Sandbox is off. "
                "vip_sudo is available for privileged operations."
            )
        else:
            msg = (
                "[SYSTEM]: Sandbox is off. vip_sudo is disabled. "
                "System sudo works normally."
            )
        return {"context": msg}
    return None


# ── Slash command handlers ──

def _handle_vipsandbox(args: str) -> str:
    args = args.strip().lower()
    # /vipsandbox net on|off
    if args.startswith("net "):
        sub = args[4:].strip()
        if sub == "on":
            sandbox.set_network_enabled(True)
            sandbox.apply_network_state()
    sandbox.apply_mount_permissions()
            return "Sandbox network enabled. Applied now."
        elif sub == "off":
            sandbox.set_network_enabled(False)
            sandbox.apply_network_state()
    sandbox.apply_mount_permissions()
            return "Sandbox network disabled. Applied now."
        else:
            net = "on" if sandbox.network_enabled() else "off"
            return f"Sandbox network: {net}. Use /vipsandbox net on|off to toggle."
    # /vipsandbox on|off
    if args == "on":
        sandbox.set_sandbox_enabled(True)
        sandbox.apply_network_state()
    sandbox.apply_mount_permissions()
        return "Sandbox enabled. Applied now."
    elif args == "off":
        sandbox.set_sandbox_enabled(False)
        return "Sandbox disabled. Applied now."
    else:
        sb = "on" if sandbox.sandbox_enabled() else "off"
        net = "on" if sandbox.network_enabled() else "off"
        vs = "on" if sandbox.vip_sudo_enabled() else "off"
        return f"Sandbox: {sb}, network: {net}, vip_sudo: {vs}"


def _handle_vipsudo(args: str) -> str:
    args = args.strip().lower()
    status = "on" if sandbox.vip_sudo_enabled() else "off"
    if args == "on":
        sandbox.set_vip_sudo_enabled(True)
        return "vip_sudo enabled. Applied now."
    elif args == "off":
        sandbox.set_vip_sudo_enabled(False)
        return "vip_sudo disabled. Applied now."
    else:
        return f"vip_sudo: {status}. Use /vipsudo on|off to toggle."


def _handle_vipdaemon(_args: str = "") -> str:
    """Show daemon status (read-only)."""
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "hermes-vipd"],
            capture_output=True, text=True, timeout=5,
        )
        status = result.stdout.strip()
    except Exception:
        status = "unknown"
    return (
        f"VIP daemon: {status}\n"
        f"Start:   sudo systemctl start hermes-vipd    (manually)\n"
        f"Stop:    sudo systemctl stop hermes-vipd     (manually)\n"
        f"Status:  sudo systemctl status hermes-vipd  (manually)"
    )
