"""
Godot tool schemas organized by category.

Mirrors the Unity-side `tools/` package shape. The schema names + arg
shapes here MUST stay in lockstep with the canonical Godot bridge tool
registry; the bridge registers tools by name and the schemas describe
them to the AI client. A parity test in `tests/test_registry_godot.py`
asserts every registered bridge tool has a schema and vice versa.

Categories follow the Godot bridge's own directory layout under
`addons/com.gladekit.mcp-bridge/tools/implementations/`:

    scene     — Node creation, hierarchy queries, transforms,
                resource assignment                              (11 tools)
    script    — GDScript file CRUD + node attachment           ( 5 tools)
    camera    — Camera3D + Light3D                              ( 2 tools)
    resource  — Material creation, generic Resource creation,
                property updates                                ( 3 tools)
    physics   — PhysicsBody3D + auto-collision-shape            ( 1 tool)
    scene_io  — .tscn create/open/save/instantiate              ( 4 tools)
    runtime   — Play-mode + selection + console + play session  ( 7 tools)
    uid       — Godot 4.4+ ResourceUID handling                 ( 2 tools)
    signal    — Persistent (scene-saved) signal wiring          ( 3 tools)
    project   — Project introspection + asset listing           ( 2 tools)
    ui        — Control-tree creation + anchor / text helpers   ( 6 tools)
                                                                ───────
                                                                46 tools

Unlike the Unity side (~222 tools across 17 categories) we expose the
full Godot catalog directly — 46 tools is well within Claude Code's
~128-tool budget so there's no need for a CORE_TOOLS filter.
"""

from typing import Dict, List

from .camera import TOOLS as CAMERA_TOOLS
from .physics import TOOLS as PHYSICS_TOOLS
from .project import TOOLS as PROJECT_TOOLS
from .resource import TOOLS as RESOURCE_TOOLS
from .runtime import TOOLS as RUNTIME_TOOLS
from .scene import TOOLS as SCENE_TOOLS
from .scene_io import TOOLS as SCENE_IO_TOOLS
from .script import TOOLS as SCRIPT_TOOLS
from .signal import TOOLS as SIGNAL_TOOLS
from .ui import TOOLS as UI_TOOLS
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
    ("signal", SIGNAL_TOOLS),
    ("project", PROJECT_TOOLS),
    ("ui", UI_TOOLS),
]


# ── Read-only tool set ────────────────────────────────────────────────────────
# Tools that only query the project / editor and never mutate it. The MCP
# layer stamps these with a `readOnlyHint` annotation so clients (Claude Code,
# Cursor, …) can auto-approve them without a per-call confirmation prompt.
#
# This MUST stay in lockstep with the bridge's authoritative list at
#   godot-bridge/addons/com.gladekit.mcp-bridge/services/read_only_guard.gd
# (the `READ_ONLY_TOOLS` const). A parity test in tests/test_registry_godot.py
# parses that file and asserts the two sets are identical, so drift in either
# direction surfaces as a failing test rather than a silently wrong annotation.
#
# Note: run_project / stop_project / launch_editor are NOT here — they are
# safe to call in play mode (requires_edit_mode = false) but they DO have
# side effects (spawn/kill a game process, focus the editor), so they are not
# read-only.
GODOT_READ_ONLY_TOOLS: frozenset = frozenset(
    {
        # Scene/Node reads
        "get_scene_tree",
        "get_node_info",
        "find_nodes",
        # Script reads
        "get_script_content",
        "find_scripts",
        # Runtime/observability reads
        "get_godot_console_logs",
        "get_play_mode_state",
        "get_selection",
        "get_debug_output",
        # UID reads
        "get_uid",
        # Signal reads
        "list_signal_connections",
        # Project introspection reads
        "get_project_info",
        "list_assets",
        # UI reads (v0.5.0)
        "list_ui_hierarchy",
    }
)


def get_godot_tool_schemas() -> List[Dict]:
    """Return all 46 Godot tool schemas as a flat list (OpenAI function format)."""
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
