"""
Script semantic search using OpenAI embeddings.

When OPENAI_API_KEY is set, ranks project scripts by cosine similarity to the
user's query. User provides their own OpenAI key — no GladeKit account required.

If OPENAI_API_KEY is absent, gracefully degrades to returning scripts unranked
(keyword-only behavior).

Usage:
    results = await search_scripts(query="jump movement", scripts=[...], top_n=5)
    # Each result has all original script fields + "similarity" score added
"""

from __future__ import annotations

import hashlib
import logging
import os
from typing import Any

logger = logging.getLogger("gladekit-mcp")

_EMBEDDING_MODEL = "text-embedding-3-small"
_DEFAULT_TOP_N = 5

# In-process cache: {content_hash: embedding_vector}
# Avoids re-embedding the same script content across multiple searches in one session.
_embedding_cache: dict[str, list[float]] = {}

# Shared AsyncOpenAI client — avoids TLS handshake per embed call.
_openai_client: Any = None

# Lazy-loaded module handles. numpy and openai are declared dependencies, but
# we import them on first use so a missing/broken install (e.g. numpy failed to
# build on an unusual platform, or the tool env is stale) only disables
# semantic search instead of crashing the whole MCP server at import time.
_np: Any = None
_openai_module: Any = None
_lazy_import_error: str | None = None


def _ensure_imports() -> bool:
    """Lazy-import numpy and openai. Returns True on success, False otherwise.
    Caches the failure reason on _lazy_import_error so callers can log once."""
    global _np, _openai_module, _lazy_import_error
    if _np is not None and _openai_module is not None:
        return True
    if _lazy_import_error is not None:
        return False
    try:
        import numpy as np_mod
        import openai as openai_mod
    except ImportError as exc:
        _lazy_import_error = str(exc)
        logger.warning(
            "Semantic search disabled — optional dependency missing: %s. "
            "Reinstall with: uv tool install --reinstall gladekit-mcp "
            "(or pip install --upgrade gladekit-mcp).",
            exc,
        )
        return False
    _np = np_mod
    _openai_module = openai_mod
    return True


def _get_openai_client():
    global _openai_client
    if _openai_client is None:
        _openai_client = _openai_module.AsyncOpenAI(api_key=os.environ["OPENAI_API_KEY"])
    return _openai_client


def is_available() -> bool:
    """Return True if semantic search is enabled (OPENAI_API_KEY is set and
    the optional numpy + openai deps are importable)."""
    if not os.environ.get("OPENAI_API_KEY"):
        return False
    return _ensure_imports()


def _hash_content(text: str) -> str:
    return hashlib.md5(text.encode()).hexdigest()


def _cosine_similarity(a: list[float], b: list[float]) -> float:
    va = _np.array(a, dtype=_np.float32)
    vb = _np.array(b, dtype=_np.float32)
    norm_a = _np.linalg.norm(va)
    norm_b = _np.linalg.norm(vb)
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return float(_np.dot(va, vb) / (norm_a * norm_b))


async def _embed_batch(texts: list[str]) -> list[list[float]]:
    """Embed a batch of texts. Returns list of embedding vectors."""
    response = await _get_openai_client().embeddings.create(model=_EMBEDDING_MODEL, input=texts)
    return [item.embedding for item in response.data]


async def search_scripts(
    query: str,
    scripts: list[dict[str, Any]],
    top_n: int = _DEFAULT_TOP_N,
) -> list[dict[str, Any]]:
    """
    Rank scripts by semantic similarity to the query.

    Each script dict should have "name", "path", and optionally "content".
    Returns the top_n most relevant scripts with a "similarity" field added.

    Degrades gracefully: returns scripts[:top_n] unranked if OPENAI_API_KEY is
    unset, or if embedding calls fail (rate limit, network error, etc.).
    """
    if not scripts:
        return []

    if not is_available():
        return [dict(s, similarity=None) for s in scripts[:top_n]]

    try:
        # Build short text representations for embedding — name + first 500 chars of content.
        # Avoids high embedding costs on large scripts while preserving enough signal.
        script_texts: list[str] = []
        content_hashes: list[str] = []

        for script in scripts:
            content = script.get("content") or ""
            text = f"{script.get('name', '')}\n{content[:500]}"
            script_texts.append(text)
            content_hashes.append(_hash_content(text))

        # Batch embed any scripts not already cached
        uncached_indices = [i for i, h in enumerate(content_hashes) if h not in _embedding_cache]
        if uncached_indices:
            uncached_texts = [script_texts[i] for i in uncached_indices]
            new_embeddings = await _embed_batch(uncached_texts)
            for idx, embedding in zip(uncached_indices, new_embeddings):
                _embedding_cache[content_hashes[idx]] = embedding
            logger.debug(f"Embedded {len(uncached_indices)} new scripts")

        # Embed the query
        query_embeddings = await _embed_batch([query])
        query_vec = query_embeddings[0]

        # Score and rank
        scored: list[dict[str, Any]] = []
        for i, script in enumerate(scripts):
            cached_vec = _embedding_cache.get(content_hashes[i])
            sim = _cosine_similarity(query_vec, cached_vec) if cached_vec is not None else 0.0
            scored.append({**script, "similarity": round(sim, 4)})

        scored.sort(key=lambda x: x["similarity"], reverse=True)
        return scored[:top_n]

    except Exception as exc:
        if _openai_module is not None and isinstance(exc, _openai_module.RateLimitError):
            logger.warning(
                "OpenAI rate limit hit during script embedding — falling back to "
                "unranked results. Try again in a moment or reduce search frequency."
            )
        else:
            logger.warning(f"Semantic search failed, falling back to unranked: {exc}")
        return [dict(s, similarity=None) for s in scripts[:top_n]]
