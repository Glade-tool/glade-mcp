"""Tests for the Godot WS bridge client.

Spins up a real `websockets.serve` server on an ephemeral port and asserts
the round-trip envelope (request id correlation, error mapping, success
payload pass-through). No Godot editor needed.

We use a real WS server (not a mock) because mocking the websockets
library's async-context-manager `connect()` is brittle — and the actual
server-side I/O path is short enough that an in-process server is
fast and produces tests that catch real wire-level bugs.
"""

from __future__ import annotations

import asyncio
import json
import sys

import pytest

# websockets is a runtime dep; tests need it too. If absent the tests
# below skip rather than fail (CI installs all deps, dev environments
# may not have it pinned).
websockets = pytest.importorskip("websockets")

from gladekit_mcp import bridge  # noqa: E402

# ── Fixtures ─────────────────────────────────────────────────────────────────


class _MockBridge:
    """In-process WS server that responds with a configured payload.

    Each accepted connection reads exactly one frame (a request envelope),
    optionally inspects it via `self.received`, and responds with
    `self.response` — mirroring the real bridge's one-shot-per-call pattern.
    """

    def __init__(self, response: dict, *, echo_id: bool = True):
        self.response = response
        self.echo_id = echo_id
        self.received: list[dict] = []
        self._server = None
        self.url = ""

    async def __aenter__(self):
        async def handler(websocket):
            raw = await websocket.recv()
            payload = json.loads(raw)
            self.received.append(payload)
            reply = dict(self.response)
            if self.echo_id and "id" in payload and "id" not in reply:
                reply["id"] = payload["id"]
            await websocket.send(json.dumps(reply))

        # Bind on an ephemeral port so multiple tests can run in parallel.
        self._server = await websockets.serve(handler, "127.0.0.1", 0)
        port = self._server.sockets[0].getsockname()[1]
        self.url = f"ws://127.0.0.1:{port}/"
        return self

    async def __aexit__(self, *_):
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()


@pytest.fixture(autouse=True)
def _reset_kind_cache():
    """Each test starts with no cached engine kind so probe order tests
    behave deterministically."""
    bridge.clear_bridge_kind_cache()
    yield
    bridge.clear_bridge_kind_cache()


# ── Health endpoint ──────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_godot_check_health_success():
    """A well-formed health response parses into the dict the caller expects."""
    payload = {
        "success": True,
        "status": "ok",
        "bridgeVersion": "0.3.0",
        "bridgeKind": "godot-mcp",
        "godotVersion": "4.3-stable",
        "engineMode": "edit",
        "toolCount": 33,
    }
    async with _MockBridge(payload) as srv:
        result = await bridge.godot_check_health(srv.url)

    assert result["status"] == "ok"
    assert result["bridgeVersion"] == "0.3.0"
    assert result["toolCount"] == 33


@pytest.mark.asyncio
async def test_godot_check_health_connection_refused_raises():
    """Bridge unreachable → GodotBridgeError, not a raw ConnectionError."""
    # Port 1 is reserved + always refused on most systems. Skip if the test
    # environment somehow has something bound there.
    with pytest.raises(bridge.GodotBridgeError) as exc_info:
        await bridge.godot_check_health("ws://127.0.0.1:1/")
    assert "Godot bridge unreachable" in str(exc_info.value)


@pytest.mark.asyncio
async def test_godot_is_available_true_when_status_ok():
    async with _MockBridge({"success": True, "status": "ok"}) as srv:
        assert await bridge.godot_is_available(srv.url) is True


@pytest.mark.asyncio
async def test_godot_is_available_false_when_unreachable():
    assert await bridge.godot_is_available("ws://127.0.0.1:1/") is False


# ── tools/execute ────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_godot_execute_tool_success_passthrough():
    """Tool result is wrapped as JSON and returned. Bridge envelope shape
    (success/message/...payload) survives the round trip."""
    payload = {
        "success": True,
        "message": "Created Node3D named 'Player' under 'Main'",
        "node_path": "Main/Player",
        "type": "Node3D",
    }
    async with _MockBridge(payload) as srv:
        result_str = await bridge.godot_execute_tool("create_node", {"type": "Node3D", "name": "Player"}, srv.url)

    result = json.loads(result_str)
    assert result["success"] is True
    assert result["node_path"] == "Main/Player"
    # Verify the bridge actually saw the tools/execute envelope it expected.
    assert srv.received[0]["endpoint"] == "tools/execute"
    assert srv.received[0]["toolName"] == "create_node"
    assert srv.received[0]["arguments"] == {"type": "Node3D", "name": "Player"}


@pytest.mark.asyncio
async def test_godot_execute_tool_bridge_error_returns_json_envelope():
    """Connection failures map to a {success: false, message: ...} envelope
    rather than raising, so the MCP client surfaces the failure in chat."""
    result_str = await bridge.godot_execute_tool("create_node", {"type": "Node3D"}, "ws://127.0.0.1:1/")
    result = json.loads(result_str)
    assert result["success"] is False
    assert "Godot bridge error" in result["message"]


@pytest.mark.asyncio
async def test_godot_execute_tool_failure_payload_passes_through():
    """A tool that returns success=false (e.g. unknown class) is forwarded
    intact — the agent reads the error from the same envelope shape."""
    payload = {
        "success": False,
        "error": "Unknown Godot class 'NotARealClass'",
        "message": "Unknown Godot class 'NotARealClass'",
    }
    async with _MockBridge(payload) as srv:
        result_str = await bridge.godot_execute_tool("create_node", {"type": "NotARealClass"}, srv.url)
    result = json.loads(result_str)
    assert result["success"] is False
    assert "NotARealClass" in result["error"]


# ── tools/list ───────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_godot_list_tools_returns_names():
    tools = ["get_scene_tree", "create_node", "find_nodes"]
    async with _MockBridge({"success": True, "tools": tools}) as srv:
        result = await bridge.godot_list_tools(srv.url)
    assert result == tools


@pytest.mark.asyncio
async def test_godot_list_tools_failure_raises():
    async with _MockBridge({"success": False, "error": "internal error"}) as srv:
        with pytest.raises(bridge.GodotBridgeError) as exc:
            await bridge.godot_list_tools(srv.url)
    assert "tools/list failed" in str(exc.value)


# ── diagnostics/recent_errors ────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_godot_recent_errors_returns_list():
    errors = [
        {"tool_name": "create_node", "error": "type required", "args_keys": []},
    ]
    async with _MockBridge({"success": True, "errors": errors, "total": 1}) as srv:
        result = await bridge.godot_recent_errors(srv.url, limit=5)
    assert result == errors


# ── Request-id correlation ───────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_godot_call_response_id_mismatch_raises():
    """The bridge MUST echo our id verbatim. A mismatch is treated as a
    protocol violation — surfaces immediately rather than letting the
    confused-state propagate."""
    # _MockBridge with echo_id=False sends a different id back.
    async with _MockBridge({"success": True, "status": "ok", "id": "wrong-id"}, echo_id=False) as srv:
        with pytest.raises(bridge.GodotBridgeError) as exc:
            await bridge.godot_check_health(srv.url)
    assert "id mismatch" in str(exc.value)


# ── Engine detection ─────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_detect_bridge_kind_godot_when_unity_unreachable(monkeypatch):
    """When the Unity HTTP probe fails but the Godot WS probe succeeds,
    detect_bridge_kind returns 'godot' and caches it."""

    async def fake_unity_unavailable(_url=bridge.DEFAULT_BRIDGE_URL):
        return False

    monkeypatch.setattr(bridge, "is_available", fake_unity_unavailable)

    async with _MockBridge({"success": True, "status": "ok"}) as srv:
        # Point the Godot default URL at our mock for the duration of the test.
        monkeypatch.setenv("GODOT_BRIDGE_URL", srv.url)
        kind = await bridge.detect_bridge_kind()

    assert kind == "godot"
    # Cached: a follow-up call returns the same answer without re-probing.
    assert await bridge.detect_bridge_kind() == "godot"


@pytest.mark.asyncio
async def test_detect_bridge_kind_unity_wins_when_both_available(monkeypatch):
    """Unity is the legacy / larger install base — it wins the probe."""

    async def fake_unity_available(_url=bridge.DEFAULT_BRIDGE_URL):
        return True

    monkeypatch.setattr(bridge, "is_available", fake_unity_available)
    async with _MockBridge({"success": True, "status": "ok"}) as srv:
        monkeypatch.setenv("GODOT_BRIDGE_URL", srv.url)
        kind = await bridge.detect_bridge_kind()
    assert kind == "unity"


@pytest.mark.asyncio
async def test_detect_bridge_kind_env_override_godot(monkeypatch):
    """GLADEKIT_MCP_FORCE_ENGINE=godot skips the probe even if Unity is up."""

    async def always_unity_available(_url=bridge.DEFAULT_BRIDGE_URL):
        return True

    monkeypatch.setattr(bridge, "is_available", always_unity_available)
    monkeypatch.setenv("GLADEKIT_MCP_FORCE_ENGINE", "godot")
    kind = await bridge.detect_bridge_kind()
    assert kind == "godot"


@pytest.mark.asyncio
async def test_detect_bridge_kind_returns_none_when_both_offline(monkeypatch):
    async def unity_down(_url=bridge.DEFAULT_BRIDGE_URL):
        return False

    monkeypatch.setattr(bridge, "is_available", unity_down)
    monkeypatch.setenv("GODOT_BRIDGE_URL", "ws://127.0.0.1:1/")
    kind = await bridge.detect_bridge_kind()
    assert kind == "none"


# ── Sanity: the new module surface ───────────────────────────────────────────


def test_module_exposes_expected_symbols():
    """Tripwire: a refactor that renames any of these breaks downstream
    callers (registry.py, server.py)."""
    expected = [
        "GodotBridgeError",
        "GodotBridgeTimeoutError",
        "godot_check_health",
        "godot_is_available",
        "godot_execute_tool",
        "godot_list_tools",
        "godot_recent_errors",
        "detect_bridge_kind",
        "clear_bridge_kind_cache",
        "DEFAULT_GODOT_BRIDGE_URL",
    ]
    for name in expected:
        assert hasattr(bridge, name), f"bridge module is missing expected symbol: {name}"


# ── Skip-on-stdlib ──────────────────────────────────────────────────────────


# asyncio.timeout was added in 3.11; our pyproject.toml requires-python ">=3.10"
# so we have to skip the timeout-specific test on 3.10. Other tests still run.
@pytest.mark.skipif(sys.version_info < (3, 11), reason="asyncio.timeout requires Python 3.11+")
@pytest.mark.asyncio
async def test_godot_call_timeout_raises():
    """A slow server triggers our wrapper timeout, not a hung process."""

    async def slow_handler(websocket):
        await asyncio.sleep(2.0)  # longer than the 0.1s timeout below
        await websocket.send(json.dumps({"success": True}))

    server = await websockets.serve(slow_handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    try:
        with pytest.raises(bridge.GodotBridgeTimeoutError) as exc:
            await bridge._godot_call(f"ws://127.0.0.1:{port}/", {"endpoint": "health"}, timeout=0.1)
        assert "timed out" in str(exc.value)
    finally:
        server.close()
        await server.wait_closed()


# ── Timeout diagnosis ────────────────────────────────────────────────────────
# After a tools/execute timeout the client probes health (served from the
# bridge's worker thread, alive even when the editor's main thread is
# blocked) and appends an actionable explanation to the error. These mock
# servers hold the tools/execute connection open until the client gives up,
# then answer the diagnosis probe per scenario.


def _hanging_bridge(health_payload: dict | None):
    """Mock bridge whose tools/execute never answers.

    health_payload of None makes health hang too (bridge fully gone);
    otherwise health answers with the given payload.
    """

    async def handler(websocket):
        raw = await websocket.recv()
        payload = json.loads(raw)
        if payload.get("endpoint") == "health" and health_payload is not None:
            reply = {"id": payload["id"], "success": True, "status": "ok", **health_payload}
            await websocket.send(json.dumps(reply))
            return
        # Hold the connection open; the client's timeout closes it.
        await websocket.wait_closed()

    return handler


@pytest.mark.skipif(sys.version_info < (3, 11), reason="asyncio.timeout requires Python 3.11+")
@pytest.mark.asyncio
async def test_execute_timeout_reports_stalled_main_thread():
    """Bridge alive + stale main-thread heartbeat → the error names the
    stall and tells the agent to dismiss the editor's modal dialog,
    instead of the bare 'timed out after Xs'."""
    handler = _hanging_bridge({"mainThreadStalledMsec": 12_000})
    server = await websockets.serve(handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    try:
        result_str = await bridge.godot_execute_tool("get_project_info", {}, f"ws://127.0.0.1:{port}/", timeout=0.2)
    finally:
        server.close()
        await server.wait_closed()
    result = json.loads(result_str)
    assert result["success"] is False
    assert "timed out" in result["message"]
    assert "stalled for ~12s" in result["message"]
    assert "modal dialog" in result["message"]


@pytest.mark.skipif(sys.version_info < (3, 11), reason="asyncio.timeout requires Python 3.11+")
@pytest.mark.asyncio
async def test_execute_timeout_reports_slow_tool_when_editor_healthy():
    """Bridge alive + fresh heartbeat → the editor is fine, the tool just
    needs longer; the error suggests retrying / splitting the request."""
    handler = _hanging_bridge({"mainThreadStalledMsec": 40})
    server = await websockets.serve(handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    try:
        result_str = await bridge.godot_execute_tool("update_project_uids", {}, f"ws://127.0.0.1:{port}/", timeout=0.2)
    finally:
        server.close()
        await server.wait_closed()
    result = json.loads(result_str)
    assert result["success"] is False
    assert "likely needs longer" in result["message"]


@pytest.mark.skipif(sys.version_info < (3, 11), reason="asyncio.timeout requires Python 3.11+")
@pytest.mark.asyncio
async def test_execute_timeout_with_legacy_health_reports_busy_or_blocked():
    """Bridges without the mainThreadStalledMsec field still get a useful
    (if less precise) diagnosis: reachable but busy/blocked."""
    handler = _hanging_bridge({})  # health ok, no heartbeat field
    server = await websockets.serve(handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    try:
        result_str = await bridge.godot_execute_tool("get_scene_tree", {}, f"ws://127.0.0.1:{port}/", timeout=0.2)
    finally:
        server.close()
        await server.wait_closed()
    result = json.loads(result_str)
    assert result["success"] is False
    assert "busy" in result["message"]


@pytest.mark.skipif(sys.version_info < (3, 11), reason="asyncio.timeout requires Python 3.11+")
@pytest.mark.asyncio
async def test_execute_timeout_with_dead_health_reports_editor_gone(monkeypatch):
    """When the diagnosis probe also hangs, report the bridge as gone
    rather than guessing at editor state."""
    # Shrink the probe timeout so the test doesn't wait the real 5s.
    monkeypatch.setattr(bridge, "GODOT_HEALTH_TIMEOUT", 0.2)
    handler = _hanging_bridge(None)  # everything hangs
    server = await websockets.serve(handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    try:
        result_str = await bridge.godot_execute_tool("get_project_info", {}, f"ws://127.0.0.1:{port}/", timeout=0.2)
    finally:
        server.close()
        await server.wait_closed()
    result = json.loads(result_str)
    assert result["success"] is False
    assert "stopped answering" in result["message"]
