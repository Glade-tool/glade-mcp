"""
Godot tool schemas organized by category.

Mirrors the Unity-side `tools/` package shape. The schema names + arg
shapes here MUST stay in lockstep with the canonical Godot bridge tool
registry; the bridge registers tools by name and the schemas describe
them to the AI client. A parity test in `tests/test_registry_godot.py`
asserts every registered bridge tool has a schema and vice versa.

Categories follow the Godot bridge's own directory layout under
`addons/com.gladekit.mcp-bridge/tools/implementations/`:

    scene     — Node creation, hierarchy queries, transforms (10 tools)
    script    — GDScript file CRUD + node attachment           ( 5 tools)
    camera    — Camera3D + Light3D                              ( 2 tools)
    resource  — Material creation + property updates            ( 2 tools)
    physics   — PhysicsBody3D + auto-collision-shape            ( 1 tool)
    scene_io  — .tscn create/open/save/instantiate              ( 4 tools)
    runtime   — Play-mode + selection + console + play session  ( 7 tools)
    uid       — Godot 4.4+ ResourceUID handling                 ( 2 tools)
                                                                ───────
                                                                33 tools

Unlike the Unity side (~222 tools across 17 categories) we expose the
full Godot catalog directly — 33 tools is well within Claude Code's
~128-tool budget so there's no need for a CORE_TOOLS filter.
"""

from typing import Dict, List

from .camera import TOOLS as CAMERA_TOOLS
from .physics import TOOLS as PHYSICS_TOOLS
from .resource import TOOLS as RESOURCE_TOOLS
from .runtime import TOOLS as RUNTIME_TOOLS
from .scene import TOOLS as SCENE_TOOLS
from .scene_io import TOOLS as SCENE_IO_TOOLS
from .script import TOOLS as SCRIPT_TOOLS
from .uid import TOOLS as UID_TOOLS

ALL_CATEGORIES = [
    ("scene", SCENE_TOOLS),
    ("script", SCRIPT_TOOLS),
    ("camera", CAMERA_TOOLS),
    ("resource", RESOURCE_TOOLS),
    ("physics", PHYSICS_TOOLS),
    ("scene_io", SCENE_IO_TOOLS),
    ("runtime", RUNTIME_TOOLS),
    ("uid", UID_TOOLS),
]


def get_godot_tool_schemas() -> List[Dict]:
    """Return all 33 Godot tool schemas as a flat list (OpenAI function format)."""
    all_tools: List[Dict] = []
    for _, tools in ALL_CATEGORIES:
        all_tools.extend(tools)
    return all_tools


def get_godot_tool_names() -> List[str]:
    """Return just the tool names, in canonical order."""
    return [t["function"]["name"] for t in get_godot_tool_schemas()]


def get_category_for_tool(tool_name: str) -> str:
    """Return the category name a Godot tool belongs to (or "" if unknown)."""
    for cat_name, tools in ALL_CATEGORIES:
        for tool in tools:
            if tool.get("function", {}).get("name") == tool_name:
                return cat_name
    return ""
