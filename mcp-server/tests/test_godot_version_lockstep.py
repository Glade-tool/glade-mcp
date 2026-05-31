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


def test_ws_server_reads_version_dynamically_not_hardcoded():
    """The bridge VERSION must be read from plugin.cfg at startup, not
    hardcoded in ws_server.gd. Caught during the 0.4.0 smoke test: an
    inline `const VERSION := "0.3.1"` in ws_server.gd silently drifted
    from the plugin.cfg bump, so /health reported the wrong version.

    Asserts the source-level invariant: no hardcoded `const VERSION :=
    "..."` line, AND the dynamic-load helper is present.
    """
    here = Path(__file__).resolve()
    bridge_root: Path | None = None
    for parent in [here, *here.parents]:
        if (parent / "godot-bridge").is_dir():
            bridge_root = parent
            break
    if bridge_root is None:
        pytest.skip("godot-bridge/ not present (mcp-server unpacked standalone)")

    ws_server = bridge_root / "godot-bridge" / "addons" / "com.gladekit.mcp-bridge" / "bridge" / "ws_server.gd"
    if not ws_server.is_file():
        pytest.skip(f"ws_server.gd not present at {ws_server}")

    src = ws_server.read_text(encoding="utf-8")

    hardcoded = re.search(
        r'^\s*const\s+VERSION\s*:?=\s*"[0-9]',
        src,
        re.MULTILINE,
    )
    assert hardcoded is None, (
        'ws_server.gd has a hardcoded `const VERSION := "X.Y.Z"` line '
        "again — that drifted from plugin.cfg in 0.4.0 and caused the "
        "/health endpoint to report the wrong version. Use ConfigFile to "
        "read plugin.cfg at startup instead (see _read_version())."
    )
    assert "_read_version" in src, (
        "ws_server.gd is missing the _read_version() helper that loads "
        "plugin.cfg dynamically. Don't remove it without replacing the "
        "version source-of-truth contract documented near it."
    )
