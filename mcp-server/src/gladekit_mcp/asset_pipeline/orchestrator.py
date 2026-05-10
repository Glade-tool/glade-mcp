"""Orchestrator — the public entry point for asset search and fetch.

v0 has a single provider (Kenney). The orchestrator is intentionally thin
but the multi-provider shape is in place: search() dispatches to every
registered provider, dedupes, ranks, and returns top N. fetch() routes by
the candidate id's provider prefix.
"""

from __future__ import annotations

import logging
from typing import Dict, List

from .providers import AssetProvider, FetchResult, KenneyProvider
from .types import AssetCandidate, AssetSpec

logger = logging.getLogger(__name__)


# Provider registry. Adding a new provider = one line here + import.
# Order does not affect ranking (candidates are re-sorted globally by score).
_PROVIDERS: Dict[str, AssetProvider] = {
    "kenney": KenneyProvider(),
}


def _provider_for_id(candidate_id: str) -> AssetProvider:
    """Resolve a candidate id ('kenney/foo') to its provider."""
    if "/" not in candidate_id:
        raise ValueError(f"Invalid candidate id {candidate_id!r}: expected '<provider>/<slug>'")
    provider_name = candidate_id.split("/", 1)[0]
    provider = _PROVIDERS.get(provider_name)
    if provider is None:
        raise ValueError(
            f"Unknown provider {provider_name!r} for candidate {candidate_id!r}. "
            f"Registered: {sorted(_PROVIDERS.keys())}"
        )
    return provider


def search(spec: AssetSpec) -> List[AssetCandidate]:
    """Multi-provider search. Returns up to spec.max_results ranked candidates.

    A provider failure does NOT short-circuit — other providers still get to
    answer. The intent is that the user always sees results from the healthy
    providers, even if one provider is unavailable.
    """
    all_candidates: List[AssetCandidate] = []
    for provider_name, provider in _PROVIDERS.items():
        try:
            results = provider.search(spec)
        except Exception:
            logger.exception(
                "Asset provider %r failed search; skipping its results",
                provider_name,
            )
            continue
        all_candidates.extend(results)

    # Global re-rank across providers.
    all_candidates.sort(key=lambda c: c.score, reverse=True)
    return all_candidates[: spec.max_results]


def fetch(candidate_id: str) -> FetchResult:
    """Resolve a candidate id to a FetchResult ready for the bridge to download."""
    return _provider_for_id(candidate_id).fetch(candidate_id)


def list_providers() -> List[str]:
    """Names of registered providers; used by /health and diagnostics."""
    return sorted(_PROVIDERS.keys())
