"""
Godot GDScript tools — file CRUD + node attachment (5 tools).

GDScript files are .gd resources living anywhere under res://. Each
Godot node can have at most one attached script (vs Unity's many
MonoBehaviour components). Use create_script + attach_script_to_node
to add behavior to a node; for built-in behaviors (physics, lights,
etc.) prefer create_node with the appropriate class instead.

modify_script enforces a session-aware safety gate: it refuses to
overwrite a .gd file the bridge did NOT create in the current Godot
session unless the caller passes confirm_existing_file_modification=true.
This protects user-authored code from accidental overwrites when the
agent misreads a "scaffold new" prompt as "extend existing".
"""

from typing import Dict, List

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "create_script",
            "description": (
                "Create a new GDScript (.gd) file at a res:// path. Refuses to overwrite "
                "an existing file — use modify_script for that. Auto-appends .gd if no "
                "extension, creates parent directories, and triggers a filesystem scan "
                "so the script shows up in the editor's FileSystem dock immediately."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "script_path": {
                        "type": "string",
                        "description": (
                            "res:// path for the new file (e.g. 'res://scripts/player.gd'). "
                            "Bare paths and '/'-prefixed paths are normalized to res://."
                        ),
                    },
                    "content": {
                        "type": "string",
                        "description": (
                            "Full file contents. Use typed GDScript and prefer the "
                            "`extends <NodeType>` + `class_name <Name>` header pattern."
                        ),
                    },
                },
                "required": ["script_path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "modify_script",
            "description": (
                "Overwrite an existing .gd file. SAFETY: refuses to modify a file the "
                "bridge did not create in this session unless confirm_existing_file_modification=true. "
                "Set the confirm flag ONLY when the user explicitly named the file to extend or "
                "modify (e.g. 'update Player.gd'). On fresh-scaffold prompts call create_script "
                "with a new path instead."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "script_path": {
                        "type": "string",
                        "description": "res:// path to an existing .gd file.",
                    },
                    "content": {
                        "type": "string",
                        "description": "Full new file contents (replaces everything).",
                    },
                    "confirm_existing_file_modification": {
                        "type": "boolean",
                        "description": (
                            "Required if the file was not created via create_script in this "
                            "session. Set true ONLY when the user explicitly asked to extend "
                            "or modify this specific file."
                        ),
                    },
                },
                "required": ["script_path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_script_content",
            "description": (
                "Read the full text contents of a .gd file. Safe in any mode (read-only). "
                "Use before modify_script to see what you're about to change."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "script_path": {
                        "type": "string",
                        "description": "res:// path to the .gd file.",
                    },
                },
                "required": ["script_path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "find_scripts",
            "description": (
                "Walk the project filesystem for .gd files matching a name pattern. "
                "Skips res://addons/ by default (Godot vendored addons are usually noise). "
                "Use before modify_script to locate an existing file by name."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "name_contains": {
                        "type": "string",
                        "description": "Case-insensitive substring on the filename. Empty matches all.",
                    },
                    "max_results": {
                        "type": "integer",
                        "description": "Default 20, clamped 1..200.",
                    },
                    "include_addons": {
                        "type": "boolean",
                        "description": "Search inside res://addons/ too. Default false.",
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "attach_script_to_node",
            "description": (
                "Attach an existing GDScript to a node in the edited scene. Each Godot "
                "node has at most ONE script — this replaces any existing attached script. "
                "The script must already exist on disk; create it with create_script first. "
                "This is Godot's analog of Unity's AddComponent<MonoBehaviour>(): for built-in "
                "physics/lights/etc. behaviors use create_node with the appropriate class instead."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "node_path": {
                        "type": "string",
                        "description": "Scene-relative path of the target node.",
                    },
                    "script_path": {
                        "type": "string",
                        "description": "res:// path to an existing .gd file.",
                    },
                },
                "required": ["node_path", "script_path"],
            },
        },
    },
]
