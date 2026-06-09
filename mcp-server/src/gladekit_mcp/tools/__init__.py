"""
Unity tool schemas organized by category.

Categories allow task-aware tool filtering: only expose tools relevant
to the current request rather than all 235+ tools simultaneously.

    Task flow:
    User message
        │
        ▼
    ┌──────────────────────────┐
    │  keyword → category map  │
    │  "animate", "blend tree" │──► animation group
    │  "red", "material"       │──► materials group
    └──────────────────────────┘
        │
        ▼
    get_tools_for_request(message) → filtered list
    (always includes ALWAYS_INCLUDED + matched groups)
"""

import os
from typing import Dict, List, Set

from .animation import CATEGORY as ANIMATION_CATEGORY
from .animation import TOOLS as ANIMATION_TOOLS
from .asset_pipeline import CATEGORY as ASSET_PIPELINE_CATEGORY
from .asset_pipeline import TOOLS as ASSET_PIPELINE_TOOLS
from .camera import CATEGORY as CAMERA_CATEGORY
from .camera import TOOLS as CAMERA_TOOLS
from .core import CATEGORY as CORE_CATEGORY
from .core import TOOLS as CORE_TOOLS
from .ik import CATEGORY as IK_CATEGORY
from .ik import TOOLS as IK_TOOLS
from .input_system import CATEGORY as INPUT_CATEGORY
from .input_system import TOOLS as INPUT_TOOLS
from .lighting import CATEGORY as LIGHTING_CATEGORY
from .lighting import TOOLS as LIGHTING_TOOLS
from .materials import CATEGORY as MATERIAL_CATEGORY
from .materials import TOOLS as MATERIAL_TOOLS
from .physics import CATEGORY as PHYSICS_CATEGORY
from .physics import TOOLS as PHYSICS_TOOLS
from .prefabs import CATEGORY as PREFAB_CATEGORY
from .prefabs import TOOLS as PREFAB_TOOLS
from .profiler import CATEGORY as PROFILER_CATEGORY
from .profiler import TOOLS as PROFILER_TOOLS
from .runtime import CATEGORY as RUNTIME_CATEGORY
from .runtime import TOOLS as RUNTIME_TOOLS
from .scene import CATEGORY as SCENE_CATEGORY
from .scene import TOOLS as SCENE_TOOLS
from .scripting import CATEGORY as SCRIPTING_CATEGORY
from .scripting import TOOLS as SCRIPTING_TOOLS
from .terrain_nav import CATEGORY as TERRAIN_NAV_CATEGORY
from .terrain_nav import TOOLS as TERRAIN_NAV_TOOLS
from .ui import CATEGORY as UI_CATEGORY
from .ui import TOOLS as UI_TOOLS
from .vfx_audio import CATEGORY as VFX_AUDIO_CATEGORY
from .vfx_audio import TOOLS as VFX_AUDIO_TOOLS

# All categories in priority order (core always first). asset_pipeline is
# included by default but suppressed when GLADEKIT_MCP_DISABLE_ASSET_PIPELINE=1
# (matches the existing GLADEKIT_MCP_SUPPRESS_BRIDGE_WARNING pattern). Studios
# working in a curated-asset workflow set this to keep the agent from offering
# external downloads.
_ASSET_PIPELINE_DISABLED = os.environ.get("GLADEKIT_MCP_DISABLE_ASSET_PIPELINE", "").strip().lower() in {
    "1",
    "true",
    "yes",
    "on",
}

ALL_CATEGORIES = [
    (CORE_CATEGORY, CORE_TOOLS),
    (SCENE_CATEGORY, SCENE_TOOLS),
    (SCRIPTING_CATEGORY, SCRIPTING_TOOLS),
    (PREFAB_CATEGORY, PREFAB_TOOLS),
    (MATERIAL_CATEGORY, MATERIAL_TOOLS),
    (LIGHTING_CATEGORY, LIGHTING_TOOLS),
    (VFX_AUDIO_CATEGORY, VFX_AUDIO_TOOLS),
    (ANIMATION_CATEGORY, ANIMATION_TOOLS),
    (IK_CATEGORY, IK_TOOLS),
    (PHYSICS_CATEGORY, PHYSICS_TOOLS),
    (PROFILER_CATEGORY, PROFILER_TOOLS),
    (CAMERA_CATEGORY, CAMERA_TOOLS),
    (UI_CATEGORY, UI_TOOLS),
    (INPUT_CATEGORY, INPUT_TOOLS),
    (TERRAIN_NAV_CATEGORY, TERRAIN_NAV_TOOLS),
    (RUNTIME_CATEGORY, RUNTIME_TOOLS),
]
if not _ASSET_PIPELINE_DISABLED:
    ALL_CATEGORIES.append((ASSET_PIPELINE_CATEGORY, ASSET_PIPELINE_TOOLS))

# Categories always included regardless of request content
ALWAYS_INCLUDED = {"core", "scene", "scripting"}


def get_unity_tool_schemas() -> List[Dict]:
    """Return all tool schemas (maintains original API for backwards compatibility)."""
    all_tools = []
    for _, tools in ALL_CATEGORIES:
        all_tools.extend(tools)
    return all_tools


def get_tool_categories() -> List[Dict]:
    """Return category metadata for all categories."""
    return [cat for cat, _ in ALL_CATEGORIES]


def get_tools_for_categories(category_names: Set[str]) -> List[Dict]:
    """Return tools for the given category names + always-included categories."""
    active = category_names | ALWAYS_INCLUDED
    result = []
    for cat, tools in ALL_CATEGORIES:
        if cat["name"] in active:
            result.extend(tools)
    return result


def get_category_for_tool(tool_name: str) -> str:
    """Return the category name for a given tool name."""
    for cat, tools in ALL_CATEGORIES:
        for tool in tools:
            if tool.get("function", {}).get("name") == tool_name:
                return cat["name"]
    return "core"
