"""
HTTP client for the Unity bridge server (localhost:8765).

The Unity bridge runs inside the Unity Editor and exposes:
  GET  /api/health             — liveness check
  POST /api/tools/execute      — run a named tool with JSON args
  POST /api/context/gather     — gather scene + project context
  GET  /api/compilation/status — check if Unity is compiling
"""

from __future__ import annotations

import asyncio
import json
import os
from typing import Any, Optional

import httpx

DEFAULT_BRIDGE_URL = os.environ.get("UNITY_BRIDGE_URL", "http://localhost:8765")

TOOL_EXECUTE_TIMEOUT = 30.0
CONTEXT_GATHER_TIMEOUT = 20.0
COMPILATION_WAIT_TIMEOUT = 90.0
COMPILATION_POLL_INTERVAL = 1.5


class UnityBridgeError(Exception):
    """Raised when the Unity bridge is unreachable or returns an unexpected error."""


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
