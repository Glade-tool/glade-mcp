"""
Godot 4.4+ ResourceUID tools (2 tools).

Godot 4.4 introduced .uid sidecar files so resource references survive
renames and moves outside the editor. The bridge enforces a version gate:
on Godot 4.3 these tools return a structured "requires Godot 4.4+" error
rather than executing — call them anyway, the agent will see the
explanatory error and pivot.

Code adapted from Coding-Solo/godot-mcp (MIT, see godot-bridge/NOTICE).
"""

from typing import Dict, List

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "get_uid",
            "description": (
                "Read the ResourceUID assigned to a resource path. Godot 4.4+ only — "
                "on older engines returns a structured error. Returns 'uid://...' string + "
                "underlying int + has_uid flag (false if Godot has not assigned one yet)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "res:// path to the resource (script, scene, material, etc.).",
                    },
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "update_project_uids",
            "description": (
                "Regenerate .uid sidecars across the project, fixing stale references that "
                "broke after manual file moves outside the editor. Godot 4.4+ only. "
                "Scans res://, skips .godot/ and addons/, resaves any resource without a UID "
                "(load + save round-trip is what mints the .uid file). Returns counts: scanned, "
                "resaved, skipped."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "subdir": {
                        "type": "string",
                        "description": (
                            "Optional: limit the scan to res://<subdir>/ instead of the whole "
                            "project. Faster for large projects when you know which directory "
                            "had stale UIDs."
                        ),
                    },
                },
            },
        },
    },
]
