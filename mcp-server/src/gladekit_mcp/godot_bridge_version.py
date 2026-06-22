"""
Godot bridge staleness warning for MCP server users.

The Godot bridge (com.gladekit.mcp-bridge) is installed via UPM git URL.
Godot caches it once on resolve and never refetches, so users drift
backward over time as new bridge features ship.

On startup and on first tool call, this module pings the bridge's
`health` WS endpoint, reads the `bridgeVersion` field, and compares
against MIN_GODOT_BRIDGE_VERSION. When stale, it:

  1. Logs a warning to stderr (visible in the MCP debug pane of Cursor /
     Claude Code / Windsurf).
  2. Returns a one-shot warning prefix that the call_tool handler prepends
     to the next tool response — so the warning surfaces in chat where
     the user actually looks.

The prefix is suppressed after the first emission per process to avoid noise.

Mirrors `bridge_version.py` (Unity) with two key differences:
  - Probes the Godot WS bridge instead of the Unity HTTP bridge.
  - Uses its own `_prefix_emitted` / `_startup_check_done` flags so the
    Godot and Unity warnings don't clobber each other when both bridges
    happen to be running.
"""

from __future__ import annotations

import os
import sys
from typing import Optional

from . import bridge

# Bump in lockstep with godot-bridge/addons/com.gladekit.mcp-bridge/plugin.cfg.
# Sync workflow tags the public repo (eventually) with v{MIN_GODOT_BRIDGE_VERSION}
# so the upgrade instruction below resolves to a real release.
MIN_GODOT_BRIDGE_VERSION = "0.7.2"

UPGRADE_INSTRUCTIONS = (
    "Update by re-downloading the addon from the GladeKit Godot bridge releases "
    f"and replacing addons/com.gladekit.mcp-bridge/ in your project (target v{MIN_GODOT_BRIDGE_VERSION} or newer)."
)

# Process-scoped one-shot suppression. Independent of the Unity equivalent
# so a dual-bridge user gets one warning per engine, not one combined.
_prefix_emitted = False
# Latch set once the version question is settled (warning emitted OR current
# bridge confirmed) so a current bridge isn't re-probed on every tool call.
# Not latched when the bridge is offline, so the check still fires later.
_check_complete = False
_startup_check_done = False


def _parse_version(v: str) -> tuple[int, ...]:
    """Tolerant semver parse — non-numeric segments become 0."""
    if not v:
        return (0,)
    cleaned = v.lstrip("vV").split("-")[0].split("+")[0]
    parts: list[int] = []
    for seg in cleaned.split("."):
        try:
            parts.append(int(seg))
        except ValueError:
            parts.append(0)
    return tuple(parts) if parts else (0,)


def _is_stale(installed: Optional[str]) -> bool:
    if not installed:
        return True
    return _parse_version(installed) < _parse_version(MIN_GODOT_BRIDGE_VERSION)


async def check_on_startup() -> None:
    """Called once when the MCP server starts. Logs a stderr warning if the
    Godot bridge is reachable but stale. Never raises — staleness is
    advisory. Silent when the Godot bridge is unreachable (the user might
    be on a Unity-only setup or just hasn't launched the editor yet)."""
    global _startup_check_done
    if _startup_check_done:
        return
    _startup_check_done = True

    try:
        health = await bridge.godot_check_health()
    except bridge.GodotBridgeError:
        # Bridge offline at startup is normal. Re-check on first tool call.
        _startup_check_done = False
        return

    installed = health.get("bridgeVersion")
    bridge_kind = health.get("bridgeKind") or "godot-mcp"

    if not _is_stale(installed):
        return

    label = installed or "<unknown>"
    print(
        f"[gladekit-mcp] WARNING: Godot bridge {label} is older than "
        f"recommended v{MIN_GODOT_BRIDGE_VERSION} (kind={bridge_kind}). "
        f"{UPGRADE_INSTRUCTIONS}",
        file=sys.stderr,
        flush=True,
    )


async def get_warning_prefix() -> str:
    """Return a one-shot warning string to prepend to a tool response, or
    "" if we should stay silent."""
    global _prefix_emitted, _check_complete
    if _check_complete:
        return ""
    if os.environ.get("GLADEKIT_MCP_SUPPRESS_BRIDGE_WARNING") == "1":
        return ""

    try:
        health = await bridge.godot_check_health()
    except bridge.GodotBridgeError:
        # Bridge offline — don't latch; re-check on a later tool call.
        return ""

    installed = health.get("bridgeVersion")
    if not _is_stale(installed):
        # Current bridge confirmed — stop probing for the rest of the process.
        _check_complete = True
        return ""

    _prefix_emitted = True
    _check_complete = True
    label = installed or "<unknown>"
    return (
        f"⚠️ GladeKit Godot bridge {label} is older than recommended v{MIN_GODOT_BRIDGE_VERSION}. "
        f"Some features (live play session, UID handling, etc.) may be unavailable. "
        f"{UPGRADE_INSTRUCTIONS}\n\n"
        f"---\n\n"
    )
