"""
Bridge staleness warning for MCP server users.

The MCP bridge (com.gladekit.mcp-bridge) is installed via UPM git URL. Unity
caches it once on resolve and never refetches, so users drift backward over
time as new bridge features ship.

On startup and on first tool call, this module pings the bridge's
/api/health endpoint, reads the bridgeVersion field (added in bridge
v0.4.0), and compares against MIN_BRIDGE_VERSION. When stale, it:

  1. Logs a warning to stderr (visible in the MCP debug pane of Cursor /
     Claude Code / Windsurf).
  2. Returns a one-shot warning prefix that the call_tool handler prepends
     to the next tool response — so the warning surfaces in the chat where
     the user actually looks.

The prefix is suppressed after the first emission per process to avoid noise.
A bridge older than v0.4.0 returns no bridgeVersion field; we treat that as
stale by definition.
"""

from __future__ import annotations

import os
import sys
from typing import Optional

from . import bridge

# Bump in lockstep with unity-bridge/package.json. The OSS sync workflow tags
# the public repo with v{MIN_BRIDGE_VERSION} so the upgrade instruction below
# resolves to a real release.
MIN_BRIDGE_VERSION = "0.7.10"

UPGRADE_INSTRUCTIONS = (
    f"Update via Unity → Window → Package Manager → GladeKit MCP Bridge → Update, "
    f"or pin manifest.json: "
    f'"com.gladekit.mcp-bridge": "https://github.com/Glade-tool/glade-mcp.git'
    f'?path=unity-bridge#v{MIN_BRIDGE_VERSION}"'
)

# Process-scoped one-shot suppression. Once the warning prefix has been
# emitted in a tool response, we don't emit it again for the rest of the
# process — the stderr line still serves as the persistent record.
_prefix_emitted = False
# Latch set once the version question is settled either way (warning emitted
# OR a current bridge confirmed). Without it, a confirmed-current bridge would
# re-probe /api/health on every single tool call forever. We deliberately do
# NOT latch on an offline bridge, so the check still fires once Unity comes up.
_check_complete = False
# Track whether the startup check has run — prevents repeat stderr spam if
# the first tool call races the lifespan startup hook.
_startup_check_done = False


def _parse_version(v: str) -> tuple[int, ...]:
    """Tolerant semver parse. Non-numeric segments become 0 — fine for our
    use case (we only compare numeric versions like 0.3.0 vs 0.4.0)."""
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
    """Bridge older than MIN, or pre-0.4.0 (no version field at all)."""
    if not installed:
        return True
    return _parse_version(installed) < _parse_version(MIN_BRIDGE_VERSION)


async def check_on_startup() -> None:
    """Called once when the MCP server starts. Logs a stderr warning if the
    bridge is unreachable or stale. Never raises — staleness is advisory."""
    global _startup_check_done
    if _startup_check_done:
        return
    _startup_check_done = True

    try:
        health = await bridge.check_health()
    except bridge.UnityBridgeError:
        # Bridge offline at startup is normal (Unity may not be running yet).
        # We'll re-check on the first tool call.
        _startup_check_done = False
        return

    installed = health.get("bridgeVersion")
    bridge_kind = health.get("bridgeKind") or "mcp"

    if not _is_stale(installed):
        return

    label = installed or "<0.4.0 (pre-version-reporting)"
    print(
        f"[gladekit-mcp] WARNING: Unity bridge {label} is older than "
        f"recommended v{MIN_BRIDGE_VERSION} (kind={bridge_kind}). "
        f"{UPGRADE_INSTRUCTIONS}",
        file=sys.stderr,
        flush=True,
    )


async def get_warning_prefix() -> str:
    """Return a one-shot warning string to prepend to a tool response, or
    "" if we should stay silent. Called inline from call_tool — does its own
    health probe so it works even if the startup check was skipped (bridge
    offline at launch but online by first tool call)."""
    global _prefix_emitted, _check_complete
    if _check_complete:
        return ""
    if os.environ.get("GLADEKIT_MCP_SUPPRESS_BRIDGE_WARNING") == "1":
        return ""

    try:
        health = await bridge.check_health()
    except bridge.UnityBridgeError:
        # Bridge offline — don't latch; re-check on a later tool call.
        return ""

    installed = health.get("bridgeVersion")
    if not _is_stale(installed):
        # Current bridge confirmed — stop probing for the rest of the process.
        _check_complete = True
        return ""

    _prefix_emitted = True
    _check_complete = True
    label = installed or "<0.4.0"
    return (
        f"⚠️ GladeKit MCP bridge {label} is older than recommended v{MIN_BRIDGE_VERSION}. "
        f'Some features (e.g. "What changed" panel, session summary) may be unavailable. '
        f"{UPGRADE_INSTRUCTIONS}\n\n"
        f"---\n\n"
    )
