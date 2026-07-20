"""
macOS sandbox - _hermes user isolation for Hermes VIP v8.0

File isolation via hermes-run wrapper.
Network isolation via sandbox-exec (--no-net flag).
"""

import logging
import shlex

logger = logging.getLogger("hermes-vip.sandbox.macos")

_HERMES_RUN = "/usr/local/bin/hermes-run"


def _build_macos_cmd(command: str, net_on: bool) -> str:
    cmd = shlex.quote(command)
    if not net_on:
        return f"{_HERMES_RUN} --no-net {cmd}"
    return f"{_HERMES_RUN} {cmd}"


def apply_network(net_on: bool):
    pass
