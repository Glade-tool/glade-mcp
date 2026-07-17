"""Tests for cloud.py — GladeKit cloud integration (RAG, memory, conventions)."""

from unittest.mock import AsyncMock, patch

import httpx
import pytest

import gladekit_mcp.cloud as cloud


@pytest.fixture(autouse=True)
def _reset_cloud_state():
    """Reset module-level state before each test."""
    cloud._cloud_available = True
    cloud._invalid_key_warned = False
    cloud._GLADEKIT_API_KEY = "test-key-123"
    cloud._http_client = None
    yield
    # Clean up shared client
    cloud._http_client = None


# ── is_available ─────────────────────────────────────────────────────────────


def test_is_available_when_key_set():
    cloud._cloud_available = True
    assert cloud.is_available() is True


def test_is_available_when_no_key():
    cloud._cloud_available = False
    assert cloud.is_available() is False


# ── _get_client ──────────────────────────────────────────────────────────────


def test_get_client_creates_shared_instance():
    client1 = cloud._get_client()
    client2 = cloud._get_client()
    assert client1 is client2
    assert isinstance(client1, httpx.AsyncClient)


def test_get_client_sets_auth_header():
    client = cloud._get_client()
    assert client.headers["authorization"] == "Bearer test-key-123"


# ── _handle_cloud_error ──────────────────────────────────────────────────────


def test_handle_cloud_error_401_disables_cloud():
    exc = httpx.HTTPStatusError(
        "401 Unauthorized",
        request=httpx.Request("POST", "http://test"),
        response=httpx.Response(401),
    )
    cloud._handle_cloud_error(exc)
    assert cloud._invalid_key_warned is True
    assert cloud._cloud_available is False


def test_handle_cloud_error_403_disables_cloud():
    exc = Exception("403 Forbidden")
    cloud._handle_cloud_error(exc)
    assert cloud._invalid_key_warned is True
    assert cloud._cloud_available is False


def test_handle_cloud_error_non_auth_does_not_disable():
    exc = Exception("500 Internal Server Error")
    cloud._handle_cloud_error(exc)
    assert cloud._invalid_key_warned is False
    assert cloud._cloud_available is True


def test_handle_cloud_error_only_warns_once():
    exc = Exception("401 Unauthorized")
    cloud._handle_cloud_error(exc)
    assert cloud._cloud_available is False

    # Reset available to test that second call is a no-op
    cloud._cloud_available = True
    cloud._handle_cloud_error(Exception("401 again"))
    # _invalid_key_warned is still True, so second call was a no-op
    assert cloud._cloud_available is True


# ── fetch_rag_context ────────────────────────────────────────────────────────


async def test_fetch_rag_context_free_tier_returns_none():
    cloud._cloud_available = False
    result = await cloud.fetch_rag_context("player movement")
    assert result is None


async def test_fetch_rag_context_success():
    mock_response = httpx.Response(
        200,
        json={"context": "Unity CharacterController docs..."},
        request=httpx.Request("POST", "http://test"),
    )
    mock_client = AsyncMock()
    mock_client.post = AsyncMock(return_value=mock_response)

    with patch.object(cloud, "_get_client", return_value=mock_client):
        result = await cloud.fetch_rag_context("player movement", top_k=3)

    assert result == "Unity CharacterController docs..."
    mock_client.post.assert_called_once()
    call_kwargs = mock_client.post.call_args
    assert "mcp-rag-query" in call_kwargs.args[0]
    # Defaults to the Unity knowledge base.
    assert call_kwargs.kwargs["json"] == {"query": "player movement", "top_k": 3, "engine": "unity"}


async def test_fetch_rag_context_sends_engine():
    """A Godot session queries the Godot knowledge base; unknown engines fall
    back to Unity."""
    mock_response = httpx.Response(
        200,
        json={"context": "CharacterBody3D move_and_slide docs..."},
        request=httpx.Request("POST", "http://test"),
    )
    mock_client = AsyncMock()
    mock_client.post = AsyncMock(return_value=mock_response)

    with patch.object(cloud, "_get_client", return_value=mock_client):
        await cloud.fetch_rag_context("how to move a body", engine="godot")
        assert mock_client.post.call_args.kwargs["json"]["engine"] == "godot"

        await cloud.fetch_rag_context("q", engine="unknown")  # unsupported -> unity
        assert mock_client.post.call_args.kwargs["json"]["engine"] == "unity"


async def test_fetch_rag_context_auth_failure_disables():
    mock_client = AsyncMock()
    mock_client.post = AsyncMock(
        side_effect=httpx.HTTPStatusError(
            "401 Unauthorized",
            request=httpx.Request("POST", "http://test"),
            response=httpx.Response(401),
        )
    )

    with patch.object(cloud, "_get_client", return_value=mock_client):
        result = await cloud.fetch_rag_context("test query")

    assert result is None
    assert cloud._cloud_available is False


async def test_fetch_rag_context_network_error_returns_none():
    mock_client = AsyncMock()
    mock_client.post = AsyncMock(side_effect=httpx.ConnectError("Connection refused"))

    with patch.object(cloud, "_get_client", return_value=mock_client):
        result = await cloud.fetch_rag_context("test query")

    assert result is None
    # Network errors don't disable cloud (not auth failure)
    assert cloud._cloud_available is True


# ── fetch_cloud_memories ─────────────────────────────────────────────────────


async def test_fetch_cloud_memories_free_tier_returns_none():
    cloud._cloud_available = False
    result = await cloud.fetch_cloud_memories("MyProject")
    assert result is None


async def test_fetch_cloud_memories_success():
    mock_response = httpx.Response(
        200,
        json={"formatted_memories": "## Conventions\n- Use PascalCase..."},
        request=httpx.Request("POST", "http://test"),
    )
    mock_client = AsyncMock()
    mock_client.post = AsyncMock(return_value=mock_response)

    with patch.object(cloud, "_get_client", return_value=mock_client):
        result = await cloud.fetch_cloud_memories("MyProject")

    assert result == "## Conventions\n- Use PascalCase..."
    call_kwargs = mock_client.post.call_args
    assert "mcp-memory-fetch" in call_kwargs.args[0]
    assert call_kwargs.kwargs["json"] == {"project_name": "MyProject"}


async def test_fetch_cloud_memories_auth_failure_disables():
    mock_client = AsyncMock()
    mock_client.post = AsyncMock(
        side_effect=httpx.HTTPStatusError(
            "403 Forbidden",
            request=httpx.Request("POST", "http://test"),
            response=httpx.Response(403),
        )
    )

    with patch.object(cloud, "_get_client", return_value=mock_client):
        result = await cloud.fetch_cloud_memories("MyProject")

    assert result is None
    assert cloud._cloud_available is False


async def test_fetch_cloud_memories_network_error_returns_none():
    mock_client = AsyncMock()
    mock_client.post = AsyncMock(side_effect=httpx.TimeoutException("timed out"))

    with patch.object(cloud, "_get_client", return_value=mock_client):
        result = await cloud.fetch_cloud_memories("MyProject")

    assert result is None
    assert cloud._cloud_available is True


# ── save_session_memory ──────────────────────────────────────────────────────


async def test_save_session_memory_free_tier_noop():
    cloud._cloud_available = False
    # Should not raise
    await cloud.save_session_memory("MyProject", "User prefers CharacterController")


async def test_save_session_memory_success():
    mock_response = httpx.Response(
        200,
        json={"ok": True},
        request=httpx.Request("POST", "http://test"),
    )
    mock_client = AsyncMock()
    mock_client.post = AsyncMock(return_value=mock_response)

    with patch.object(cloud, "_get_client", return_value=mock_client):
        await cloud.save_session_memory("MyProject", "User prefers CharacterController")

    mock_client.post.assert_called_once()
    call_kwargs = mock_client.post.call_args
    assert "mcp-memory-save" in call_kwargs.args[0]
    assert call_kwargs.kwargs["json"] == {
        "project_name": "MyProject",
        "summary": "User prefers CharacterController",
    }


async def test_save_session_memory_error_does_not_raise():
    mock_client = AsyncMock()
    mock_client.post = AsyncMock(
        side_effect=httpx.HTTPStatusError(
            "500 Internal Server Error",
            request=httpx.Request("POST", "http://test"),
            response=httpx.Response(500),
        )
    )

    with patch.object(cloud, "_get_client", return_value=mock_client):
        # Should not raise
        await cloud.save_session_memory("MyProject", "some memory")

    # 500 is not auth failure, cloud stays available
    assert cloud._cloud_available is True
