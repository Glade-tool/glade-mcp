"""Drift guard for the Godot bridge staleness floor.

When the Godot bridge version in plugin.cfg bumps, the MCP server's
staleness floor must bump in lockstep — otherwise users on the latest
bridge get a false-positive warning, or genuinely stale users get no
warning at all. Parses plugin.cfg at test time so the assertion is
mechanical.

Skips when the bridge isn't a sibling — happens when mcp-server/ is
unpacked standalone from a sdist. Same pattern as test_registry_godot.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from gladekit_mcp.godot_bridge_version import MIN_GODOT_BRIDGE_VERSION


def _plugin_cfg_version() -> str:
    here = Path(__file__).resolve()
    bridge_root: Path | None = None
    for parent in [here, *here.parents]:
        if (parent / "godot-bridge").is_dir():
            bridge_root = parent
            break
    if bridge_root is None:
        pytest.skip("godot-bridge/ not present (mcp-server unpacked standalone)")

    plugin_cfg = bridge_root / "godot-bridge" / "addons" / "com.gladekit.mcp-bridge" / "plugin.cfg"
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


def test_min_godot_bridge_version_matches_plugin_cfg():
    """MIN_GODOT_BRIDGE_VERSION must match the bridge it ships against."""
    bridge_version = _plugin_cfg_version()
    assert MIN_GODOT_BRIDGE_VERSION == bridge_version, (
        f"Drift: plugin.cfg version is {bridge_version} but "
        f"MIN_GODOT_BRIDGE_VERSION is {MIN_GODOT_BRIDGE_VERSION}. Bump "
        f"src/gladekit_mcp/godot_bridge_version.py to match."
    )
