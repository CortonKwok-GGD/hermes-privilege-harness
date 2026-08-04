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



def _market_intel_ssh(args: dict) -> str:
    """Execute market-intel on 167 via SSH, transparent to the model."""
    import json, shlex, subprocess

    raw = args.get("raw_args", "")
    if raw:
        cmd = f"/usr/local/bin/market-intel {raw}"
    else:
        # Structured args - reconstruct CLI
        raw_args = args.get("raw_args", args.get("args", ""))
        cmd = f"/usr/local/bin/market-intel {shlex.quote(str(raw_args))}"

    try:
        result = subprocess.run(
            ["ssh", "hermes-test@10.0.0.6", cmd],
            capture_output=True, text=True,
            timeout=60,
        )
        out = result.stdout or ""
        err = result.stderr or ""
        if result.returncode != 0:
            return json.dumps({"error": err.strip(), "exit_code": result.returncode})
        return out.strip() or err.strip()
    except subprocess.TimeoutExpired:
        return json.dumps({"error": "market-intel timed out on 167"})
    except Exception as e:
        return json.dumps({"error": str(e)})


def _register_market_intel(ctx):
    """Register market-intel tool."""
    ctx.register_tool(
        name="market-intel",
        toolset="market-intel",
        description=(
            "查询股票实时行情、指数、K线数据。用法: q 股票名/代码"
        ),
        schema={
            "name": "market-intel",
            "parameters": {
                "type": "object",
                "properties": {
                    "raw_args": {
                        "type": "string",
                        "description": "market-intel CLI arguments, e.g. 'query 600519' or 'index cn'"
                    },
                },
                "required": ["raw_args"],
            },
        },
        handler=lambda args, **kw: _market_intel_ssh(
            args if isinstance(args, dict) else {"raw_args": str(args)}
        ),
        is_async=False,
    )


def register(ctx):
    _inject_git_push_pattern()
    _patch_approval_display()
    guard._register_stamp_cap()

    # ── pre_tool_call hook ──
    ctx.register_hook("pre_tool_call", _hook)

    # ── vip_sudo tool (conditional on config) ──
    _register_vip_sudo(ctx)

    # ── market-intel SSH proxy (executes on 167 via tinc) ──
    _register_market_intel(ctx)

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
    """pre_tool_call: stringify all arg values, then delegate to guard.check()"""
    # Hermes may pass int instead of str (e.g. {"query": 513050})
    if isinstance(args, dict):
        for k, v in args.items():
            if not isinstance(v, str):
                args[k] = str(v)
    return guard.check(tool_name, args if isinstance(args, dict) else {})


def _inject(**kwargs):
    if kwargs.get("is_first_turn"):
        sb_on = sandbox.sandbox_enabled()
        vs_on = sandbox.vip_sudo_enabled()
        net_on = sandbox.network_enabled()
        if sb_on and vs_on:
            msg = (
                "[SYSTEM]: You are in a sandbox. "
                "Terminal handles files, network, scripts — no approval needed. "
                "vip_sudo is the only tool that requires approval."
            )
            if not net_on:
                msg += " Network is isolated. Ask user for /vipsandbox net on if needed."
        elif sb_on and not vs_on:
            msg = (
                "[SYSTEM]: You are in a sandbox. "
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
    """Show daemon status via Unix socket connectivity."""
    import json, struct, socket
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(3)
        s.connect('/var/run/hermes-vip/request.sock')
        req = json.dumps({'type': 'ping'}).encode()
        s.sendall(struct.pack('!I', len(req)) + req)
        data = s.recv(4)
        s.close()
        status = 'active' if len(data) == 4 else 'unknown'
    except FileNotFoundError:
        status = 'stopped'
    except (ConnectionRefusedError, OSError):
        status = 'stopped'
    except Exception:
        status = 'unknown'
    return f'VIP daemon: {status}'

