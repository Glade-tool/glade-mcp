"""Asset pipeline domain types. Stdlib dataclasses — no pydantic dep.

Validation lives in `AssetSpec.from_dict` (the entry point from LLM tool args)
and is intentionally narrow: enforce required fields and enum membership; let
unknown extra fields silently drop so the schema can evolve without breaking
older clients.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from enum import Enum
from typing import Any, Dict, List, Optional


class AssetType(str, Enum):
    SPRITE_2D = "sprite_2d"
    MODEL_3D = "model_3d"
    AUDIO_SFX = "audio_sfx"
    AUDIO_MUSIC = "audio_music"
    ANIMATION = "animation"
    UI_SPRITE = "ui_sprite"


class License(str, Enum):
    """Normalized license enum. Provider-specific licenses map to one of these."""

    CC0 = "CC0-1.0"
    CC_BY = "CC-BY-4.0"
    CC_BY_SA = "CC-BY-SA-4.0"
    MIT = "MIT"
    # User-owned generative output (e.g. AI-generated 3D models). Reserved
    # for future providers — no generative provider is registered today.
    MESHY_USER_OWNED = "MESHY-USER-OWNED"
    UNKNOWN = "UNKNOWN"

    @property
    def attribution_required(self) -> bool:
        return self in (License.CC_BY, License.CC_BY_SA, License.MIT)

    @property
    def commercial_ok(self) -> bool:
        return self in (
            License.CC0,
            License.CC_BY,
            License.CC_BY_SA,
            License.MIT,
            License.MESHY_USER_OWNED,
        )


def _coerce_enum(value, enum_cls, field_name: str):
    """Accept either an enum instance or its string value; raise ValueError otherwise."""
    if value is None:
        return None
    if isinstance(value, enum_cls):
        return value
    if isinstance(value, str):
        try:
            return enum_cls(value)
        except ValueError as exc:
            valid = sorted(m.value for m in enum_cls)
            raise ValueError(
                f"{field_name}={value!r} is not a valid {enum_cls.__name__}. Expected one of {valid}."
            ) from exc
    raise TypeError(f"{field_name} must be {enum_cls.__name__} or str, got {type(value).__name__}")


@dataclass
class AssetSpec:
    """What the user wants. The agent fills this from natural language."""

    description: str
    asset_type: AssetType
    style: Optional[str] = None
    tags: List[str] = field(default_factory=list)
    license_constraint: Optional[License] = None
    max_results: int = 8

    def __post_init__(self) -> None:
        if not self.description or not self.description.strip():
            raise ValueError("description is required and must be non-empty")
        # asset_type must already be an enum here — from_dict handles coercion.
        if not isinstance(self.asset_type, AssetType):
            raise TypeError("asset_type must be an AssetType")
        if self.license_constraint is not None and not isinstance(self.license_constraint, License):
            raise TypeError("license_constraint must be a License or None")
        if not isinstance(self.tags, list):
            raise TypeError("tags must be a list")
        if not isinstance(self.max_results, int):
            raise TypeError("max_results must be an int")
        if not (1 <= self.max_results <= 32):
            raise ValueError("max_results must be in [1, 32]")

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "AssetSpec":
        """Build from raw dict (e.g. parsed LLM tool-call arguments). Coerces
        enum fields and tolerates missing optionals; raises with a clear message
        on bad input."""
        if not isinstance(data, dict):
            raise TypeError(f"AssetSpec input must be a dict, got {type(data).__name__}")
        return cls(
            description=str(data.get("description", "") or "").strip(),
            asset_type=_coerce_enum(data.get("asset_type"), AssetType, "asset_type"),
            style=data.get("style"),
            tags=list(data.get("tags") or []),
            license_constraint=_coerce_enum(data.get("license_constraint"), License, "license_constraint"),
            max_results=int(data.get("max_results") or 8),
        )


@dataclass
class AssetCandidate:
    """A single search result from a provider. Stable id; provider-opaque payload."""

    id: str
    provider: str
    name: str
    description: str
    asset_type: AssetType
    license: License
    license_summary: str
    license_url: Optional[str] = None
    attribution_required: bool = False
    attribution_recommended: Optional[str] = None
    style: Optional[str] = None
    tags: List[str] = field(default_factory=list)
    approx_assets: Optional[int] = None
    official_page: Optional[str] = None
    thumbnail_url: Optional[str] = None
    download_url: Optional[str] = None
    score: float = 0.0

    def to_dict(self) -> Dict[str, Any]:
        """JSON-safe dict for serialization to LLM tool_result."""
        d = asdict(self)
        d["asset_type"] = self.asset_type.value
        d["license"] = self.license.value
        return d
