"""Provider adapters. Each provider implements AssetProvider (see base.py)."""

from .base import AssetProvider, FetchResult
from .kenney import KenneyProvider

__all__ = ["AssetProvider", "FetchResult", "KenneyProvider"]
