"""
Bridge clients for the GladeKit editor bridges. Dual-protocol:

  Unity    — HTTP client for the Unity bridge server (localhost:8765)
             /api/health, /api/tools/execute, /api/context/gather,
             /api/compilation/status, /api/batch
  Godot    — WebSocket client for the Godot bridge server (localhost:8766)
             ws://...:8766/ with endpoint envelope {id, endpoint, toolName, arguments}

Unity is the legacy path and stays byte-identical for backward compatibility.
Godot was added in v0.3.0 of the Godot bridge.
Engine selection happens at the registry layer via a one-shot health probe;
the bridge module itself exposes parallel `_unity` / `_godot` namespaces and
a thin dispatcher routes based on the detected bridge kind.

Environment overrides:
  UNITY_BRIDGE_URL              — base HTTP URL for the Unity bridge
  GODOT_BRIDGE_URL              — base WS URL for the Godot bridge
  GLADEKIT_MCP_FORCE_ENGINE     — skip probe, force 'unity' or 'godot'
"""

from __future__ import annotations

import asyncio
import json
import os
import uuid
from typing import Any, Optional

import httpx

DEFAULT_BRIDGE_URL = os.environ.get("UNITY_BRIDGE_URL", "http://localhost:8765")
DEFAULT_GODOT_BRIDGE_URL = os.environ.get("GODOT_BRIDGE_URL", "ws://localhost:8766/")

TOOL_EXECUTE_TIMEOUT = 30.0
CONTEXT_GATHER_TIMEOUT = 20.0
COMPILATION_WAIT_TIMEOUT = 90.0
COMPILATION_POLL_INTERVAL = 1.5

# Godot bridge timeouts. Health and tools/list answer on the bridge's
# worker thread (sub-10ms p99). tools/execute hits the main thread —
# 30s matches Unity's tool budget so per-call behavior is consistent.
GODOT_HEALTH_TIMEOUT = 5.0
GODOT_TOOL_EXECUTE_TIMEOUT = 30.0

# Editor main-thread stall reporting. The Godot bridge's health endpoint
# answers from its worker thread even while the editor's main thread (where
# tools execute) is blocked, and bridges >= 0.6.6 report how long the main
# thread has been silent via `mainThreadStalledMsec`. After a tool timeout
# we probe health and treat a stall at or above this threshold as "the
# editor is wedged" rather than "the tool is slow".
GODOT_STALL_REPORT_THRESHOLD_MSEC = 5_000


class UnityBridgeError(Exception):
    """Raised when the Unity bridge is unreachable or returns an unexpected error."""


class GodotBridgeError(Exception):
    """Raised when the Godot bridge is unreachable or returns an unexpected error."""


class GodotBridgeTimeoutError(GodotBridgeError):
    """Raised when a Godot bridge call exceeds its deadline.

    Distinct from the base error so callers can run extra diagnosis on
    timeouts (the bridge being reachable-but-stalled needs different user
    guidance than the bridge being gone).
    """


# Shared HTTP client — keepalive connections avoid the TCP-connect tax on every
# bridge call. Lazily created inside an async context so we don't bind to a
# loop the caller doesn't own.
_client: Optional[httpx.AsyncClient] = None


def _get_client() -> httpx.AsyncClient:
    global _client
    if _client is None:
        _client = httpx.AsyncClient(
            limits=httpx.Limits(max_keepalive_connections=5, keepalive_expiry=30.0),
        )
    return _client


async def aclose_client() -> None:
    """Close the shared client. Safe to call multiple times."""
    global _client
    if _client is not None:
        await _client.aclose()
        _client = None


# ── Health / availability ────────────────────────────────────────────────────


async def check_health(bridge_url: str = DEFAULT_BRIDGE_URL) -> dict:
    """Ping /api/health. Returns health dict or raises UnityBridgeError."""
    url = f"{bridge_url}/api/health"
    try:
        resp = await _get_client().get(url, timeout=5.0)
        resp.raise_for_status()
        return resp.json()
    except Exception as exc:
        raise UnityBridgeError(f"Unity bridge not reachable at {bridge_url}: {exc}") from exc


async def is_available(bridge_url: str = DEFAULT_BRIDGE_URL) -> bool:
    """Return True if the Unity bridge is running and healthy."""
    try:
        health = await check_health(bridge_url)
        return health.get("status") == "ok"
    except UnityBridgeError:
        return False


# ── Tool execution ───────────────────────────────────────────────────────────


async def execute_tool(
    tool_name: str,
    arguments: dict[str, Any],
    bridge_url: str = DEFAULT_BRIDGE_URL,
    timeout: float = TOOL_EXECUTE_TIMEOUT,
    wait_for_compilation: bool = True,
) -> str:
    """
    Execute a named tool against the Unity bridge.

    Returns a JSON string with the tool result. On errors, returns a JSON
    error object rather than raising so the MCP client can display it.
    """
    url = f"{bridge_url}/api/tools/execute"
    body = {"toolName": tool_name, "arguments": json.dumps(arguments)}

    try:
        resp = await _get_client().post(
            url,
            json=body,
            timeout=timeout,
            headers={"Content-Type": "application/json"},
        )
        data = resp.json()
    except httpx.HTTPStatusError as exc:
        return json.dumps(
            {
                "success": False,
                "message": f"HTTP {exc.response.status_code} from Unity bridge for {tool_name}",
            }
        )
    except Exception as exc:
        detail = str(exc) or type(exc).__name__
        return json.dumps({"success": False, "message": f"Unity bridge error for {tool_name}: {detail}"})

    if not data.get("success"):
        return json.dumps(
            {
                "success": False,
                "message": data.get("error") or "Tool execution failed in Unity",
            }
        )

    # Some tools trigger C# compilation (e.g. create_script). Wait for it.
    if wait_for_compilation and data.get("requiresCompilation"):
        baseline_count = data.get("compilationCount", -1)
        await _wait_for_compilation(bridge_url, baseline_count=baseline_count)

    result_str = data.get("result")
    if result_str is None:
        return json.dumps({"success": True, "message": "Tool executed"})
    return result_str


# ── Batch execution ──────────────────────────────────────────────────────────


async def execute_batch(
    calls: list[dict],
    bridge_url: str = DEFAULT_BRIDGE_URL,
    timeout: float = TOOL_EXECUTE_TIMEOUT * 2,
) -> list[dict]:
    """
    Execute multiple tool calls in a single HTTP request to the Unity bridge.

    Each call is a dict with 'toolName' and 'arguments' (dict, not string).
    Returns a list of result dicts with 'toolName', 'success', 'result'/'error'.
    On transport-level failure, returns a single-element list with the error.
    """
    url = f"{bridge_url}/api/batch"
    body = {
        "calls": [
            {
                "toolName": c["toolName"],
                "arguments": json.dumps(c.get("arguments", {})),
            }
            for c in calls
        ]
    }

    try:
        resp = await _get_client().post(
            url,
            json=body,
            timeout=timeout,
            headers={"Content-Type": "application/json"},
        )
        data = resp.json()
    except Exception as exc:
        return [{"toolName": "batch", "success": False, "error": f"Unity bridge error: {exc}"}]

    if not data.get("success"):
        return [{"toolName": "batch", "success": False, "error": data.get("error", "Batch execution failed")}]

    results = data.get("results", [])

    # Check if any tool requires compilation and wait once at the end
    any_compilation = any(r.get("requiresCompilation") for r in results)
    if any_compilation:
        await _wait_for_compilation(bridge_url)

    return results


# ── Scene context ────────────────────────────────────────────────────────────


async def gather_scene_context(bridge_url: str = DEFAULT_BRIDGE_URL) -> dict:
    """
    Call /api/context/gather and return the parsed context dict.

    Returns keys like sceneHierarchy, scripts, projectInfo, etc.
    Raises UnityBridgeError if the bridge is unreachable.
    """
    url = f"{bridge_url}/api/context/gather"

    try:
        resp = await _get_client().post(
            url,
            json={},
            timeout=CONTEXT_GATHER_TIMEOUT,
            headers={"Content-Type": "application/json"},
        )
        outer = resp.json()
    except Exception as exc:
        raise UnityBridgeError(f"Could not gather scene context: {exc}") from exc

    context_raw = outer.get("context", "{}")
    if isinstance(context_raw, str):
        try:
            return json.loads(context_raw)
        except json.JSONDecodeError as exc:
            raise UnityBridgeError(f"Could not parse context JSON: {exc}") from exc
    return context_raw


# ── Compilation wait ─────────────────────────────────────────────────────────


async def _wait_for_compilation(
    bridge_url: str,
    timeout_seconds: float = COMPILATION_WAIT_TIMEOUT,
    baseline_count: int = -1,
) -> None:
    """
    Poll /api/compilation/status until Unity finishes compiling or timeout expires.

    Uses compilationCount to avoid a race condition: Unity may not have started
    compiling yet when we first poll, so checking isCompiling alone can return
    a false "idle" immediately.  If baseline_count is provided (from the tool
    response), we wait until compilationCount > baseline_count, which means a
    new compilation has actually completed.
    """
    url = f"{bridge_url}/api/compilation/status"
    elapsed = 0.0
    saw_compiling = False
    while elapsed < timeout_seconds:
        try:
            resp = await _get_client().get(url, timeout=5.0)
            status = resp.json()
            is_compiling = status.get("isCompiling", False)
            current_count = status.get("compilationCount", -1)

            if is_compiling:
                saw_compiling = True

            # If we have a baseline count, wait for it to increment
            if baseline_count >= 0 and current_count > baseline_count:
                return  # A new compilation completed

            # Fallback: if we saw compiling start, wait for it to finish
            if saw_compiling and not is_compiling:
                return

        except Exception:
            pass
        await asyncio.sleep(COMPILATION_POLL_INTERVAL)
        elapsed += COMPILATION_POLL_INTERVAL


# ════════════════════════════════════════════════════════════════════════════
# Godot bridge — WebSocket client
# ════════════════════════════════════════════════════════════════════════════
#
# Wire protocol (per godot-bridge/README.md):
#   Request:  {"id": str, "endpoint": "health"|"tools/list"|"tools/execute"
#                                      |"diagnostics/recent_errors",
#              "toolName": str, "arguments": dict|str}
#   Response: {"id": str, "success": bool, "message": str, ...payload}
#
# The Godot bridge accepts persistent connections — we use one connection
# per call (simple, robust against editor restarts) but the framework is
# in place to add connection pooling later if needed.


async def godot_check_health(bridge_url: str = DEFAULT_GODOT_BRIDGE_URL) -> dict:
    """Send a `health` envelope to the Godot bridge. Returns health dict.

    Raises GodotBridgeError on connection failure or malformed response.
    """
    response = await _godot_call(bridge_url, {"endpoint": "health"}, timeout=GODOT_HEALTH_TIMEOUT)
    if not response.get("success"):
        raise GodotBridgeError(f"Godot bridge health probe failed: {response.get('error', 'unknown')}")
    return response


async def godot_is_available(bridge_url: str = DEFAULT_GODOT_BRIDGE_URL) -> bool:
    """Return True if the Godot bridge is reachable and healthy."""
    try:
        h = await godot_check_health(bridge_url)
        return h.get("status") == "ok"
    except GodotBridgeError:
        return False


async def godot_execute_tool(
    tool_name: str,
    arguments: dict[str, Any],
    bridge_url: str = DEFAULT_GODOT_BRIDGE_URL,
    timeout: float = GODOT_TOOL_EXECUTE_TIMEOUT,
) -> str:
    """Run a Godot bridge tool. Returns a JSON string with the tool result.

    Matches `execute_tool`'s contract: returns a JSON error envelope on
    connection/protocol failure rather than raising, so the MCP client
    surfaces the message in chat.
    """
    try:
        response = await _godot_call(
            bridge_url,
            {
                "endpoint": "tools/execute",
                "toolName": tool_name,
                "arguments": arguments,
            },
            timeout=timeout,
        )
    except GodotBridgeTimeoutError as exc:
        # A bare timeout is ambiguous (slow tool? wedged editor? dead
        # bridge?) and ambiguity makes agents flail — e.g. concluding the
        # bridge is broken and abandoning it after one stuck modal dialog.
        # Health answers from the bridge's worker thread even while the
        # editor's main thread is blocked, so a follow-up probe can say
        # which of the three it is.
        diagnosis = await _diagnose_godot_timeout(bridge_url, timeout)
        return json.dumps(
            {
                "success": False,
                "message": f"Godot bridge error for {tool_name}: {exc}. {diagnosis}",
            }
        )
    except GodotBridgeError as exc:
        return json.dumps({"success": False, "message": f"Godot bridge error for {tool_name}: {exc}"})
    # The bridge already returns {success, message, ...payload}; just stringify.
    return json.dumps(response)


async def godot_list_tools(bridge_url: str = DEFAULT_GODOT_BRIDGE_URL) -> list[str]:
    """Return the bridge's registered tool names. Raises on failure."""
    response = await _godot_call(bridge_url, {"endpoint": "tools/list"}, timeout=GODOT_HEALTH_TIMEOUT)
    if not response.get("success"):
        raise GodotBridgeError(f"tools/list failed: {response.get('error', 'unknown')}")
    return list(response.get("tools", []))


async def godot_recent_errors(
    bridge_url: str = DEFAULT_GODOT_BRIDGE_URL,
    limit: int = 10,
) -> list[dict]:
    """Read the per-session error tracker from the Godot bridge."""
    response = await _godot_call(
        bridge_url,
        {"endpoint": "diagnostics/recent_errors", "limit": limit},
        timeout=GODOT_HEALTH_TIMEOUT,
    )
    if not response.get("success"):
        raise GodotBridgeError(f"recent_errors failed: {response.get('error', 'unknown')}")
    return list(response.get("errors", []))


async def _diagnose_godot_timeout(bridge_url: str, tool_timeout: float) -> str:
    """Explain a tools/execute timeout via a follow-up health probe.

    The bridge serves health from its worker thread, which stays responsive
    even when the editor's main thread (where tools execute) is blocked by a
    modal dialog or a long synchronous operation. Probing health after a
    tool timeout therefore distinguishes three states a bare timeout can't:

      1. health unreachable      → editor crashed / closed / hard-frozen
      2. health ok, stale tick   → main thread wedged (modal dialog etc.)
      3. health ok, fresh tick   → editor fine; the tool just ran long

    Returns one actionable sentence to append to the timeout error. Never
    raises — diagnosis is best-effort decoration of an error we already have.
    """
    try:
        health = await _godot_call(bridge_url, {"endpoint": "health"}, timeout=GODOT_HEALTH_TIMEOUT)
    except GodotBridgeError:
        return (
            "The bridge has stopped answering entirely — the Godot editor may have "
            "crashed, been closed, or hard-frozen. Verify the editor is running, then retry."
        )

    stalled_msec = health.get("mainThreadStalledMsec")
    if isinstance(stalled_msec, (int, float)) and stalled_msec >= GODOT_STALL_REPORT_THRESHOLD_MSEC:
        return (
            f"The bridge is reachable, but the editor's main thread has been stalled for "
            f"~{stalled_msec / 1000:.0f}s — usually an open modal dialog or a long synchronous "
            "operation. Ask the user to switch to the Godot editor and dismiss any open "
            "dialog, then retry."
        )
    if isinstance(stalled_msec, (int, float)):
        return (
            f"The bridge and editor are responsive, so the tool likely needs longer than "
            f"the {tool_timeout:.0f}s limit. Retry, or break the request into smaller steps."
        )
    # Pre-0.6.6 bridge: health works but doesn't report the main-thread
    # heartbeat, so we can't tell "wedged" from "busy".
    return (
        "The bridge is reachable, so the editor is likely busy with a long operation or "
        "blocked by a modal dialog. Check the Godot editor window, then retry."
    )


async def _godot_call(bridge_url: str, payload: dict, *, timeout: float) -> dict:
    """One-shot request/response over a fresh WebSocket connection.

    Generates a request id, opens the WS, sends the envelope, awaits a
    matching response (by id), closes. The bridge echoes ids verbatim so
    we can verify correlation. Raises GodotBridgeError on any I/O,
    decode, or correlation failure.

    We import websockets lazily so users who only ever talk to Unity
    don't pay the import cost. The dependency is declared in
    pyproject.toml so it ships with `pip install gladekit-mcp`.
    """
    try:
        import websockets  # type: ignore[import-not-found]
    except ImportError as exc:  # pragma: no cover — pyproject pins websockets
        raise GodotBridgeError(
            "websockets package is not installed; reinstall gladekit-mcp to pick up the Godot bridge support"
        ) from exc

    request_id = uuid.uuid4().hex
    envelope = {"id": request_id, **payload}
    try:
        async with asyncio.timeout(timeout):
            async with websockets.connect(bridge_url) as ws:
                await ws.send(json.dumps(envelope))
                # The bridge serializes by request id; on a fresh connection
                # the next frame IS our response.
                raw = await ws.recv()
    except asyncio.TimeoutError as exc:
        raise GodotBridgeTimeoutError(f"Godot bridge call timed out after {timeout}s") from exc
    except Exception as exc:
        # websockets raises ConnectionClosed, InvalidURI, OSError, etc. —
        # collapse them all into one bridge error so callers handle
        # uniformly.
        raise GodotBridgeError(f"Godot bridge unreachable at {bridge_url}: {exc}") from exc

    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise GodotBridgeError(f"Godot bridge returned non-JSON response: {exc}") from exc

    if not isinstance(data, dict):
        raise GodotBridgeError(f"Godot bridge returned non-dict response: {type(data).__name__}")

    # Correlation check — defensive but cheap.
    if data.get("id") and data["id"] != request_id:
        raise GodotBridgeError(f"Godot bridge response id mismatch (sent {request_id}, got {data['id']})")

    return data


# ── Engine kind detection ────────────────────────────────────────────────────
#
# Single source of truth for "which engine bridge is reachable right now?"
# Probed once at first tool list / first tool call and cached for the
# lifetime of the process. Env override `GLADEKIT_MCP_FORCE_ENGINE` skips
# the probe — useful for power users running both bridges simultaneously.
#
# Probe order: Unity first (larger install base), Godot second. If both
# are reachable and no env override is set, Unity wins.

_cached_bridge_kind: Optional[str] = None


async def detect_bridge_kind() -> str:
    """Probe local bridges and return the active engine kind.

    Returns one of:
      "unity" — Unity HTTP bridge reachable on :8765
      "godot" — Godot WS bridge reachable on :8766
      "none"  — neither reachable (likely no editor running yet)

    Cached after the first call; call `clear_bridge_kind_cache()` to retry.
    """
    global _cached_bridge_kind
    if _cached_bridge_kind is not None:
        return _cached_bridge_kind

    forced = os.environ.get("GLADEKIT_MCP_FORCE_ENGINE", "").strip().lower()
    if forced in {"unity", "godot"}:
        _cached_bridge_kind = forced
        return forced

    # Re-read URLs at call time so env-var overrides set after import are
    # honored. The module-level DEFAULT_* constants are captured at import
    # time, so passing them implicitly (via function default args) would
    # miss late changes.
    unity_url = os.environ.get("UNITY_BRIDGE_URL", "http://localhost:8765")
    godot_url = os.environ.get("GODOT_BRIDGE_URL", "ws://localhost:8766/")

    # Unity first (legacy + larger install base).
    if await is_available(unity_url):
        _cached_bridge_kind = "unity"
        return "unity"

    if await godot_is_available(godot_url):
        _cached_bridge_kind = "godot"
        return "godot"

    # Neither reachable. Don't cache — bridges may come online later.
    return "none"


def clear_bridge_kind_cache() -> None:
    """Reset the cached engine kind. Forces the next detect_bridge_kind()
    to re-probe. Mainly for tests."""
    global _cached_bridge_kind
    _cached_bridge_kind = None
