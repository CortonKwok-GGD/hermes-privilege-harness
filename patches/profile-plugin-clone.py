"""
VIP Plugin Clone Patch
======================
Injects into create_profile() in hermes_cli/profiles.py.

Unified behavior: whether cloning from default or creating fresh,
always symlink all global plugins (~/.hermes/plugins/) into the
new profile's plugins/ directory. No deep copies — avoids VZ file
sharing / permission issues on macOS container sandbox.

source_dir parameter kept in signature for backward compatibility
with the call site (create_profile passes it), but ignored.
"""

import os
from pathlib import Path


def _sync_profile_plugins(profile_dir: Path, source_dir: Path | None) -> None:
    """Symlink all global plugins into profile_dir/plugins/."""
    from hermes_cli.profiles import _get_default_hermes_home as _root

    target = profile_dir / "plugins"
    target.mkdir(parents=True, exist_ok=True)

    global_plugins = _root() / "plugins"
    if not global_plugins.is_dir():
        return

    for entry in global_plugins.iterdir():
        if not entry.is_dir():
            continue
        link = target / entry.name
        if link.exists():
            continue
        try:
            link.symlink_to(entry, target_is_directory=True)
        except OSError:
            pass
