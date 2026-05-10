"""Provider ABC. Every asset source implements this contract."""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Dict, List, Optional

from ..types import AssetCandidate, AssetSpec


@dataclass
class FetchResult:
    """What fetch() returns: a directly-downloadable URL plus authoritative metadata.

    The Unity bridge consumes this — `download_url` must be a stable HTTP(S)
    URL the bridge can GET without auth (or with a single short-lived auth header
    we pass via auth_headers). For packs, `download_url` points at the archive
    (.zip / .tar.gz); the bridge handles extraction.
    """

    candidate_id: str
    download_url: str
    license_at_fetch: str
    archive_format: Optional[str] = None  # "zip", "tar.gz", or None for single-file
    file_extension: Optional[str] = None  # for single-file: ".png", ".wav", ".fbx"
    attribution_text: Optional[str] = None
    auth_headers: Dict[str, str] = field(default_factory=dict)


class AssetProvider(ABC):
    """Search-and-fetch contract for an asset source.

    Design rules:
        - search() is sync and fast. In-memory index lookup is preferred;
          cached HTTP is acceptable. No live scraping per-search.
        - fetch() may hit the network — it resolves a candidate to a stable
          download URL. Called only when the user accepts an import.
        - Providers do NOT touch the filesystem or Unity. They return URLs;
          the bridge downloads.
    """

    @property
    @abstractmethod
    def name(self) -> str:
        """Provider identifier, used in candidate.provider and as id prefix."""

    @abstractmethod
    def search(self, spec: AssetSpec) -> List[AssetCandidate]:
        """Return ranked candidates matching `spec`. Bounded by spec.max_results."""

    @abstractmethod
    def fetch(self, candidate_id: str) -> FetchResult:
        """Resolve a candidate id to a downloadable URL + metadata.

        Raises ValueError if the candidate id isn't owned by this provider
        or can't be resolved.
        """
