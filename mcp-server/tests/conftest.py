"""Shared fixtures for MCP server tests."""

from __future__ import annotations

import json
from unittest.mock import patch

import pytest


@pytest.fixture
def mock_bridge_success():
    """Patch bridge.execute_tool to return a generic success response."""

    async def _execute(tool_name, args, **kwargs):
        return json.dumps({"success": True, "message": f"{tool_name} executed"})

    with patch("gladekit_mcp.bridge.execute_tool", new=_execute) as m:
        yield m


@pytest.fixture
def mock_bridge_health():
    """Patch bridge.check_health to return a healthy response."""

    async def _health(bridge_url=None):
        return {
            "status": "ok",
            "unityVersion": "6000.0.0f1",
            "projectName": "TestProject",
            "projectPath": "/tmp/TestProject",
        }

    with patch("gladekit_mcp.bridge.check_health", new=_health):
        yield


@pytest.fixture
def mock_bridge_context():
    """Patch bridge.gather_scene_context to return a test scene."""

    async def _gather(bridge_url=None):
        return {
            "sceneHierarchy": [
                {"name": "Main Camera", "path": "Main Camera"},
                {"name": "Player", "path": "Player"},
            ],
            "scripts": [
                {"name": "PlayerController", "path": "Assets/Scripts/PlayerController.cs"},
            ],
            "selection": {"selectedObjects": [{"name": "Player"}]},
        }

    with patch("gladekit_mcp.bridge.gather_scene_context", new=_gather):
        yield


@pytest.fixture(autouse=True)
def reset_session_memory():
    """Clear session memory, skill, and telemetry state between tests."""
    from gladekit_mcp import server, skill, telemetry

    server._session_memory.clear()
    skill._session_messages.clear()
    skill._last_persisted_count.clear()
    telemetry.reset()
    telemetry.reset_clock()
    yield
    server._session_memory.clear()
    skill._session_messages.clear()
    skill._last_persisted_count.clear()
    telemetry.reset()
    telemetry.reset_clock()


@pytest.fixture(autouse=True)
def reset_shared_http_clients():
    """Reset module-level httpx clients between tests.

    pytest-asyncio creates a fresh event loop per test. Shared clients are
    loop-bound, so reusing one across tests trips RuntimeError. Resetting
    forces a fresh client on each test's loop.
    """
    from gladekit_mcp import bridge, cloud, search

    bridge._client = None
    cloud._http_client = None
    search._openai_client = None
    yield
    bridge._client = None
    cloud._http_client = None
    search._openai_client = None


@pytest.fixture(autouse=True)
def pin_engine_to_unity():
    """Pin the engine probe cache to "unity" for every test.

    The test suite's mocks (mock_bridge_success, the in-process bridge HTTP
    mock in test_integration) model the Unity bridge's HTTP API. If a real
    Godot bridge happens to be listening on the local WS port during a test
    run (e.g. the user has the editor open), the first dispatch_tool_call
    triggers a live probe, sets _active_engine = "godot", and routes
    subsequent Unity-shaped tests through the Godot dispatch path — where
    create_game_object et al. are unknown tools. Forcing the cache hermetic
    avoids that environmental coupling.

    Belt-and-suspenders: pin BOTH the canonical registry module and any
    stale registry instances reachable via `gladekit_mcp.server`'s imported
    function refs. `test_asset_pipeline._reload_tools_pkg()` deletes
    `gladekit_mcp.tools.*` from sys.modules to re-read an env var, which
    leaves server.py's `dispatch_tool_call` reference bound to the OLD
    module — and its `_active_engine` global lives there, not on the
    newly-imported registry.
    """
    import sys

    from gladekit_mcp.tools import registry as registry_mod

    prev = registry_mod._active_engine
    registry_mod._active_engine = "unity"

    # Patch any stale registry module accessible via server.py function refs.
    stale_modules = []
    srv = sys.modules.get("gladekit_mcp.server")
    if srv is not None:
        for attr_name in ("dispatch_tool_call", "get_active_engine", "get_mcp_tools_async"):
            fn = getattr(srv, attr_name, None)
            globs = getattr(fn, "__globals__", None)
            if globs is not None and "_active_engine" in globs and globs is not registry_mod.__dict__:
                stale_modules.append((globs, globs["_active_engine"]))
                globs["_active_engine"] = "unity"

    yield

    registry_mod._active_engine = prev
    for globs, prior in stale_modules:
        globs["_active_engine"] = prior
