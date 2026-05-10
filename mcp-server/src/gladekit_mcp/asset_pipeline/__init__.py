"""
Asset pipeline — orchestration over external asset providers (free libraries
first, AI generation later).

The pipeline does NOT generate assets itself. It indexes and routes to
providers (Kenney CC0 packs in v0; Freesound, Quaternius, Replicate-hosted
SD coming next), normalizes their license metadata, and hands the chosen
asset to the Unity bridge for download + import-settings configuration.

Public surface:
    AssetSpec       — what the user wants ("coin sprite, pixel art, 16x16")
    AssetCandidate  — what a provider offers (provider, license, preview, fetch info)
    License         — normalized license enum (CC0, CC_BY, CC_BY_SA, MIT, ...)
    AssetType       — sprite_2d / model_3d / audio_sfx / audio_music / animation
    search()        — multi-provider search; returns ranked AssetCandidate list
    fetch()         — resolve a candidate to a downloadable URL + metadata

Provider design contract (see providers/base.py):
    - search() is sync, in-memory, fast. Pure index lookup OR cached HTTP.
    - fetch() may hit the network to resolve the latest download URL.
    - No provider holds API keys directly; the orchestrator passes credentials
      from settings when needed (BYOK in v1).
"""

from .orchestrator import fetch, search
from .types import AssetCandidate, AssetSpec, AssetType, License

__all__ = [
    "AssetSpec",
    "AssetCandidate",
    "License",
    "AssetType",
    "search",
    "fetch",
]
