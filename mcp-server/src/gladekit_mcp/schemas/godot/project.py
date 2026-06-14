"""
Godot project tools (3): introspection + input map setup.

`get_project_info` answers "what is this Godot project?" in a single
call — name, version, renderer, main scene, currently edited scene,
counts of scenes/scripts/resources, enabled addons, and (in detailed
mode) bounded file listings + the input map.

Designed to replace the 4-5 exploratory tool calls an agent typically
makes when dropped into an unknown project. Consolidates the kind of
discovery that competitor MCP servers expose as separate
list-scenes / list-scripts / get-project-version tools.

`list_assets` enumerates referenceable media; both are read-only and safe
in play mode. `add_input_action` is the one mutating tool here — it defines
custom InputMap actions (WASD, jump, etc.) so action-based input scripts
have actions to reference.
"""

from typing import Dict, List

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "get_project_info",
            "description": (
                "Single-call snapshot of the Godot project: name, version, "
                "renderer, main scene, currently edited scene, counts of "
                "scenes/scripts/resources, and enabled addons. Use this "
                "first when working with an unfamiliar project — it answers "
                'most "what kind of project is this and what\'s in it" '
                "questions without needing 4-5 separate exploratory calls.\n\n"
                "CRITICAL for tool choice: the response includes "
                "`workspace` ('2d' | '3d' | 'ui' | 'other' | 'unknown'), the "
                "project's primary dimension inferred from the main scene's "
                "root node. In a '2d' project reach for the 2D node families "
                "(create_camera/create_light/create_material with space='2d', "
                "create_sprite_2d, create_animated_sprite_2d, Sprite2D / "
                "Camera2D / CharacterBody2D); in a '3d' project use the 3D "
                "families. Do NOT drop a Camera3D into a 2D game.\n\n"
                'Use `response_format="detailed"` when planning broader '
                "changes — it adds bounded file listings (top 50 scenes / "
                "50 scripts / 30 resources, each as `{path, name}` for "
                "scenes/scripts or `{path, format}` for resources where "
                "format is 'tres' or 'res'), top-level directory layout, "
                "and the custom input actions — only those explicitly "
                "saved in project.godot's `[input]` section (engine `ui_*` "
                "defaults and in-editor shortcuts like `spatial_editor/*` "
                "are filtered out). File scans are capped so the call stays "
                "fast on pathological projects; truncation is signaled via "
                "`*_truncated: true` flags on the response.\n\n"
                "Read-only; safe to call in play mode."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "response_format": {
                        "type": "string",
                        "enum": ["concise", "detailed"],
                        "description": (
                            "'concise' (default) returns just project "
                            "metadata + counts (~150 tokens). 'detailed' "
                            "additionally returns scene/script/resource "
                            "listings, top-level dirs, and the input map "
                            "(~500 tokens for typical projects)."
                        ),
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_assets",
            "description": (
                "List the project's referenceable assets — textures, audio, "
                "models, scenes, Godot resources (.tres/.res), fonts, and "
                "shaders — each tagged with a coarse `type` ('texture', "
                "'audio', 'model', 'scene', 'resource', 'font', 'shader'). "
                "Complements get_project_info, whose project walk only counts "
                "scenes/scripts/resources and never enumerates raw media. "
                "Scripts are excluded — use find_scripts for those. Results "
                "are sorted by path and bounded; `truncated` signals a cap was "
                "hit. Read-only; safe to call in play mode."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "type_filter": {
                        "type": "string",
                        "enum": [
                            "texture",
                            "audio",
                            "model",
                            "scene",
                            "resource",
                            "font",
                            "shader",
                        ],
                        "description": ("Restrict results to one asset category. Omit to return every kind."),
                    },
                    "name_contains": {
                        "type": "string",
                        "description": ("Case-insensitive substring filter on the filename. Empty matches all assets."),
                    },
                    "max_results": {
                        "type": "integer",
                        "description": ("Maximum number of assets to return (default 200, clamped 1..1000)."),
                    },
                    "include_addons": {
                        "type": "boolean",
                        "description": ("Include assets under res://addons/. Default false."),
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "add_input_action",
            "description": (
                "Define (or replace) a custom InputMap action and bind keyboard "
                "keys to it. A fresh Godot project ships with only the engine "
                "`ui_*` defaults, so a script that calls "
                '`Input.is_action_pressed("move_forward")` or '
                "`Input.get_vector(...)` with custom action names errors every "
                "frame unless the action exists. Call this FIRST to register "
                "movement / jump / interact actions, then write input code "
                "against them.\n\n"
                "The action is saved to project.godot (survives restarts, shows "
                "under Project Settings > Input Map) AND registered live so it "
                "fires the moment the project runs. Keys bind as PHYSICAL keys "
                "so WASD stays put on non-QWERTY layouts. Re-running with "
                "overwrite=true (the default) is idempotent. Mutating; refused "
                "during play mode."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "action_name": {
                        "type": "string",
                        "description": ("Action identifier, e.g. 'move_forward', 'jump'. snake_case by convention."),
                    },
                    "keys": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": (
                            "Key names to bind, e.g. ['W', 'Up']. Editor-style "
                            "names: letters/digits, 'Space', 'Escape', 'Shift', "
                            "'Enter', 'Tab', arrow keys "
                            "('Up'/'Down'/'Left'/'Right'). Case-insensitive."
                        ),
                    },
                    "deadzone": {
                        "type": "number",
                        "description": "Analog deadzone, 0..1 (default 0.5).",
                    },
                    "overwrite": {
                        "type": "boolean",
                        "description": (
                            "When the action already exists, replace its "
                            "bindings (default true). Set false to fail instead "
                            "of clobbering an existing action."
                        ),
                    },
                },
                "required": ["action_name", "keys"],
            },
        },
    },
]
