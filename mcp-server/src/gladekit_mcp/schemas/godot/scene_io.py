"""
Godot scene I/O tools — .tscn create/open/save/instantiate (4 tools).

Godot scenes are .tscn (text) or .scn (binary) PackedScene resources.
The active scene in the editor is exposed via EditorInterface; scene I/O
either reads from / writes to that, or instantiates a saved PackedScene
into the active scene as a scene-instance (the chain-link icon in the
Scene dock).
"""

from typing import Dict, List

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "create_scene",
            "description": (
                "Create a new .tscn scene file with a single root node and (by default) "
                "open it in the editor. Refuses to overwrite an existing scene. "
                "root_type accepts any instantiable ClassDB class OR a user-declared "
                "`class_name` from a project script."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "res:// path for the new scene. Auto-appends .tscn.",
                    },
                    "root_type": {
                        "type": "string",
                        "description": "Class for the scene root. Default 'Node3D'.",
                    },
                    "root_name": {
                        "type": "string",
                        "description": "Name of the root node. Defaults to root_type.",
                    },
                    "open": {
                        "type": "boolean",
                        "description": "Open the new scene immediately in the editor. Default true.",
                    },
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "open_scene",
            "description": (
                "Open an existing .tscn / .scn scene in the editor and make it the "
                "edited scene. Returns the previously-edited scene path so you can "
                "navigate back later."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "res:// path to a .tscn or .scn file.",
                    },
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "save_scene",
            "description": (
                "Save the currently edited scene to disk. Requires a `path` arg on the "
                "first save (scene has no file path yet); subsequent saves are idempotent. "
                "Snapshots the existing file to <project>/.gladekit-backups/ before "
                "overwriting so a prior version can be recovered."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": (
                            "res:// path. Only required on first save (when scene has no scene_file_path yet)."
                        ),
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "instantiate_scene",
            "description": (
                "Instantiate a PackedScene (.tscn) into the edited scene tree. The Godot "
                "equivalent of Unity's instantiate_prefab. Adds the instance as a "
                "scene-instance (chain-link icon in editor) so future scene saves keep "
                "the link intact."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "scene_path": {
                        "type": "string",
                        "description": "res:// path to a .tscn or .scn.",
                    },
                    "parent_path": {
                        "type": "string",
                        "description": "Scene-relative parent. Default scene root.",
                    },
                    "name": {
                        "type": "string",
                        "description": "Name for the instantiated root. Defaults to PackedScene's root name.",
                    },
                    "position": {
                        "type": "string",
                        "description": "Initial position for Node3D-rooted scenes, as 'x,y,z'.",
                    },
                },
                "required": ["scene_path"],
            },
        },
    },
]
