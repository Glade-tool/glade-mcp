"""Drift guard for the Godot bridge version lockstep.

When the Godot bridge version in plugin.cfg bumps, two sibling pins must
bump in lockstep so the staleness warning and the desktop installer
target the right release:

  1. mcp-server/src/gladekit_mcp/godot_bridge_version.py
       → MIN_GODOT_BRIDGE_VERSION (staleness floor for the MCP server)
  2. glade-electron/src/shared/config.ts
       → MIN_GODOT_BRIDGE_VERSION (release tag the installer fetches)

The 0.3.0 → 0.3.1 bump silently missed pin #1; this test makes that
class of drift impossible to land again.

Each assertion skips when its companion file is absent — the OSS publish
flow syncs mcp-server/ + godot-bridge/ to a public repo where
glade-electron/ does not exist, so the Electron pin can only be checked
in the monorepo.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from gladekit_mcp.godot_bridge_version import MIN_GODOT_BRIDGE_VERSION


def _repo_root() -> Path | None:
    """Walk up from this file looking for the godot-bridge/ sibling.

    Returns None when not found — happens when mcp-server/ is unpacked
    standalone from a PyPI sdist. The tests below skip in that case.
    """
    here = Path(__file__).resolve()
    for parent in [here, *here.parents]:
        if (parent / "godot-bridge").is_dir():
            return parent
    return None


def _plugin_cfg_version() -> str:
    root = _repo_root()
    if root is None:
        pytest.skip("godot-bridge/ not present (mcp-server synced standalone)")
    plugin_cfg = root / "godot-bridge" / "addons" / "com.gladekit.mcp-bridge" / "plugin.cfg"
    if not plugin_cfg.is_file():
        pytest.skip(f"plugin.cfg not present at {plugin_cfg}")

    # plugin.cfg uses INI-style `version="X.Y.Z"`.
    match = re.search(
        r'^\s*version\s*=\s*"([^"]+)"',
        plugin_cfg.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    assert match, f"Couldn't parse version= line in {plugin_cfg}"
    return match.group(1)


def test_godot_bridge_version_matches_plugin_cfg():
    """MIN_GODOT_BRIDGE_VERSION must match the bridge it ships against,
    otherwise users with the latest bridge get a false-positive staleness
    warning (floor too high) or genuinely stale users get no warning at
    all (floor too low)."""
    bridge_version = _plugin_cfg_version()
    assert MIN_GODOT_BRIDGE_VERSION == bridge_version, (
        f"Drift: plugin.cfg version is {bridge_version} but "
        f"MIN_GODOT_BRIDGE_VERSION is {MIN_GODOT_BRIDGE_VERSION}. "
        f"Bump mcp-server/src/gladekit_mcp/godot_bridge_version.py to match — "
        f"see CLAUDE.md 'Releasing a new MCP bridge version' for the full "
        f"Godot lockstep."
    )


def test_electron_config_matches_plugin_cfg():
    """The Electron installer fetches the GitHub release tagged
    `godot-v{MIN_GODOT_BRIDGE_VERSION}`. If this pin drifts behind the
    actual bridge version, the installer hits a 404 on a tag that exists
    but isn't yet published, or pulls an older addon than what the
    monorepo ships."""
    root = _repo_root()
    if root is None:
        pytest.skip("godot-bridge/ not present (mcp-server synced standalone)")
    electron_config = root / "glade-electron" / "src" / "shared" / "config.ts"
    if not electron_config.is_file():
        pytest.skip(f"glade-electron/ not present at {electron_config}")

    match = re.search(
        r'MIN_GODOT_BRIDGE_VERSION\s*=\s*"([^"]+)"',
        electron_config.read_text(encoding="utf-8"),
    )
    assert match, "Couldn't find MIN_GODOT_BRIDGE_VERSION in config.ts"

    bridge_version = _plugin_cfg_version()
    assert match.group(1) == bridge_version, (
        f"Drift: plugin.cfg is {bridge_version} but "
        f"glade-electron/src/shared/config.ts MIN_GODOT_BRIDGE_VERSION is "
        f"{match.group(1)}. The Electron installer will fetch the wrong tag."
    )
