"""
Godot project introspection (1 tool).

`get_project_info` answers "what is this Godot project?" in a single
call — name, version, renderer, main scene, currently edited scene,
counts of scenes/scripts/resources, enabled addons, and (in detailed
mode) bounded file listings + the input map.

Designed to replace the 4-5 exploratory tool calls an agent typically
makes when dropped into an unknown project. Consolidates the kind of
discovery that competitor MCP servers expose as separate
list-scenes / list-scripts / get-project-version tools.

Read-only and safe in play mode.
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
]
