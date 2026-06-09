"""
GladeKit cloud integration — activated by GLADEKIT_API_KEY env var.

Without the API key, all functions return None silently (free tier behavior).
With the key, these functions call GladeKit's cloud API for:
  - RAG knowledge base: curated Unity docs, API corrections, error patterns
  - Cross-session persistent memory: AI-extracted memories from past sessions
  - Convention extraction: coding patterns distilled from accumulated memories

Free tier (no key needed):
  - All 235+ Unity tools via local Unity bridge
  - Script semantic search (bring your own OPENAI_API_KEY)
  - GLADE.md injection (reads from Unity project root)
  - In-session memory (current conversation only)
  - Heuristic skill calibration (persisted locally)
"""

from __future__ import annotations

import logging
import os
from typing import Optional

import httpx

logger = logging.getLogger("gladekit-mcp")

_GLADEKIT_API_KEY = os.environ.get("GLADEKIT_API_KEY")
_CLOUD_BASE_URL = os.environ.get("GLADEKIT_CLOUD_URL", "https://api.gladekit.com/functions/v1")

# Whether cloud features are available in this session.
# Set to False on auth failure (401/403) to stop wasting requests.
_cloud_available = bool(_GLADEKIT_API_KEY)

if _cloud_available:
    logger.info("GladeKit cloud features enabled (RAG + cross-session memory)")
else:
    logger.debug(
        "GLADEKIT_API_KEY not set — running in free tier mode. "
        "Set GLADEKIT_API_KEY to enable RAG knowledge base and cross-session memory."
    )

# Tracks whether we've already warned about an invalid key this session
_invalid_key_warned = False

# Shared HTTP client for connection reuse across cloud calls
_http_client: Optional[httpx.AsyncClient] = None


def _get_client() -> httpx.AsyncClient:
    """Return a shared httpx client, creating one on first use."""
    global _http_client
    if _http_client is None:
        _http_client = httpx.AsyncClient(
            headers={"Authorization": f"Bearer {_GLADEKIT_API_KEY}"},
            timeout=15.0,
        )
    return _http_client


async def aclose_client() -> None:
    """Close the shared cloud client. Safe to call multiple times."""
    global _http_client
    if _http_client is not None:
        await _http_client.aclose()
        _http_client = None


def _handle_cloud_error(exc: Exception) -> None:
    """Disable cloud features on auth failure (401/403). Log a one-time warning."""
    global _invalid_key_warned, _cloud_available
    if _invalid_key_warned:
        return
    err_str = str(exc).lower()
    if "401" in err_str or "403" in err_str or "unauthorized" in err_str or "forbidden" in err_str:
        logger.warning(
            "GLADEKIT_API_KEY is set but the server returned an auth error — "
            "cloud features disabled for this session. Check your API key at gladekit.com."
        )
        _invalid_key_warned = True
        _cloud_available = False


def is_available() -> bool:
    """Return True if GladeKit cloud features are enabled."""
    return _cloud_available


async def fetch_rag_context(query: str, top_k: int = 5) -> Optional[str]:
    """
    Retrieve relevant Unity knowledge from GladeKit's RAG knowledge base.

    Returns a formatted string of relevant Unity docs, API corrections, and
    error patterns relevant to the query. Returns None when unavailable.

    Requires GLADEKIT_API_KEY.
    """
    if not _cloud_available:
        return None

    try:
        client = _get_client()
        resp = await client.post(
            f"{_CLOUD_BASE_URL}/mcp-rag-query",
            json={"query": query, "top_k": top_k},
            timeout=15.0,
        )
        resp.raise_for_status()
        data = resp.json()
        return data.get("context")
    except Exception as exc:
        _handle_cloud_error(exc)
        logger.debug("RAG query failed: %s", exc)
        return None


async def fetch_cloud_memories(project_name: str) -> Optional[str]:
    """
    Load cross-session memories for this project from GladeKit's cloud.

    Returns a formatted memory block (conventions + past session summaries)
    for injection into the system prompt. Returns None when unavailable.

    Requires GLADEKIT_API_KEY.
    """
    if not _cloud_available:
        return None

    try:
        client = _get_client()
        resp = await client.post(
            f"{_CLOUD_BASE_URL}/mcp-memory-fetch",
            json={"project_name": project_name},
            timeout=10.0,
        )
        resp.raise_for_status()
        data = resp.json()
        return data.get("formatted_memories")
    except Exception as exc:
        _handle_cloud_error(exc)
        logger.debug("Memory fetch failed: %s", exc)
        return None


async def save_session_memory(project_name: str, session_summary: str) -> None:
    """
    Persist a session summary to GladeKit's cloud memory for future sessions.

    Requires GLADEKIT_API_KEY. A no-op in free tier mode.
    """
    if not _cloud_available:
        return

    try:
        client = _get_client()
        resp = await client.post(
            f"{_CLOUD_BASE_URL}/mcp-memory-save",
            json={
                "project_name": project_name,
                "summary": session_summary,
            },
            timeout=10.0,
        )
        resp.raise_for_status()
    except Exception as exc:
        _handle_cloud_error(exc)
        logger.debug("Memory save failed: %s", exc)
