"""Kenney.nl provider — CC0 game asset packs.

Loads `catalogs/kenney.json` once at construction. Search is in-memory keyword
scoring. Fetch resolves a candidate to its (pre-baked) download URL.

The index is hand-curated for v0. Run `scripts/build_kenney_index.py` to
refresh and populate per-pack `download_url` values from kenney.nl.
"""

from __future__ import annotations

import json
import logging
import re
from functools import lru_cache
from pathlib import Path
from typing import List, Optional

from ..types import AssetCandidate, AssetSpec, AssetType, License
from .base import AssetProvider, FetchResult

logger = logging.getLogger(__name__)

_CATALOG_PATH = Path(__file__).resolve().parent.parent / "catalogs" / "kenney.json"

# Tokens that aren't useful for matching (too generic).
_STOPWORDS = {
    "the",
    "a",
    "an",
    "of",
    "for",
    "with",
    "and",
    "or",
    "to",
    "in",
    "asset",
    "assets",
    "pack",
    "sprite",
    "sprites",
}

# Provider-specific license string -> normalized License enum.
_LICENSE_MAP = {
    "CC0-1.0": License.CC0,
}


@lru_cache(maxsize=1)
def _load_catalog() -> dict:
    if not _CATALOG_PATH.exists():
        raise FileNotFoundError(
            f"Kenney catalog not found at {_CATALOG_PATH}. Run scripts/build_kenney_index.py to generate it."
        )
    with _CATALOG_PATH.open("r", encoding="utf-8") as f:
        return json.load(f)


def _tokenize(text: str) -> List[str]:
    return [t for t in re.findall(r"[a-z0-9]+", text.lower()) if t not in _STOPWORDS]


def _score(spec: AssetSpec, pack: dict) -> float:
    """Keyword overlap score in [0, 1]. Higher = more relevant.

    Weights:
        - Explicit tag match: 3.0 each
        - Description token in candidate tags/name/description: 1.0 each
        - Style match: 1.5
        - Description token appearing as substring of candidate name: 2.0 (boost
          for direct mentions like 'platformer' matching 'Platformer Pack')
    """
    score = 0.0

    pack_tags = {t.lower() for t in pack.get("tags", [])}
    pack_text_tokens = set(_tokenize(pack.get("name", "") + " " + pack.get("description", "")))
    pack_name_lower = pack.get("name", "").lower()

    # Explicit tag matches
    for tag in spec.tags:
        if tag.lower() in pack_tags:
            score += 3.0

    # Description tokens
    desc_tokens = _tokenize(spec.description)
    for token in desc_tokens:
        if token in pack_tags:
            score += 1.0
        elif token in pack_text_tokens:
            score += 0.5
        if token in pack_name_lower:
            score += 2.0

    # Style match
    if spec.style:
        if spec.style.lower() == (pack.get("style") or "").lower():
            score += 1.5
        elif spec.style.lower() in pack_tags:
            score += 1.0

    # Normalize loosely — clamp to [0, 1] for downstream ranker.
    # 12 is a soft cap chosen by inspection; rare packs hit higher and still rank highest.
    return min(score / 12.0, 1.0)


class KenneyProvider(AssetProvider):
    @property
    def name(self) -> str:
        return "kenney"

    def search(self, spec: AssetSpec) -> List[AssetCandidate]:
        catalog = _load_catalog()

        # Normalize provider license once per catalog (all Kenney packs are CC0).
        provider_license = _LICENSE_MAP.get(catalog.get("license"), License.UNKNOWN)
        if provider_license == License.UNKNOWN:
            logger.warning(
                "Kenney catalog license %r not in _LICENSE_MAP; treating as UNKNOWN",
                catalog.get("license"),
            )

        # License-constraint filter
        if spec.license_constraint is not None and spec.license_constraint != provider_license:
            return []

        candidates: List[AssetCandidate] = []
        for pack in catalog.get("packs", []):
            # Asset type filter (must match exactly)
            if pack.get("asset_type") != spec.asset_type.value:
                continue

            relevance = _score(spec, pack)
            if relevance == 0.0:
                # Skip totally unrelated packs to keep results crisp.
                continue

            candidates.append(
                AssetCandidate(
                    id=pack["id"],
                    provider=self.name,
                    name=pack["name"],
                    description=pack["description"],
                    asset_type=AssetType(pack["asset_type"]),
                    license=provider_license,
                    license_summary=catalog.get("license_summary", ""),
                    license_url=catalog.get("license_url"),
                    attribution_required=catalog.get("attribution_required", False),
                    attribution_recommended=catalog.get("attribution_recommended"),
                    style=pack.get("style"),
                    tags=pack.get("tags", []),
                    approx_assets=pack.get("approx_assets"),
                    official_page=pack.get("official_page"),
                    thumbnail_url=pack.get("thumbnail_url"),
                    download_url=pack.get("download_url"),
                    score=relevance,
                )
            )

        candidates.sort(key=lambda c: c.score, reverse=True)
        return candidates[: spec.max_results]

    def fetch(self, candidate_id: str) -> FetchResult:
        catalog = _load_catalog()
        pack = next(
            (p for p in catalog.get("packs", []) if p.get("id") == candidate_id),
            None,
        )
        if pack is None:
            raise ValueError(f"Kenney candidate not found: {candidate_id}")

        download_url: Optional[str] = pack.get("download_url")
        if not download_url:
            raise ValueError(
                f"Kenney candidate {candidate_id} has no download_url. "
                f"Run scripts/build_kenney_index.py to refresh the catalog "
                f"and resolve download URLs from {pack.get('official_page')}."
            )

        provider_license = _LICENSE_MAP.get(catalog.get("license"), License.UNKNOWN)

        attribution_text = None
        if catalog.get("attribution_recommended"):
            attribution_text = (
                f"Asset from {catalog['attribution_recommended']} ({pack.get('official_page', 'https://kenney.nl')})."
            )

        return FetchResult(
            candidate_id=candidate_id,
            download_url=download_url,
            archive_format="zip",
            file_extension=None,
            license_at_fetch=provider_license.value,
            attribution_text=attribution_text,
        )
