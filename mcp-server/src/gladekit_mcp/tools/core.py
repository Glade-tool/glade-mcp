"""
Core category tools — always included in every request.
Covers: user input, thinking, scene/console queries, compilation, save/open.
"""

from typing import Dict, List

CATEGORY = {
    "name": "core",
    "display_name": "Core & Scene Management",
    "keywords": [
        "help",
        "question",
        "think",
        "scene",
        "hierarchy",
        "console",
        "log",
        "error",
        "compile",
        "refresh",
        "save",
        "open",
        "build",
        "list scenes",
    ],
}

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "request_user_input",
            "description": "Ask a clarifying question when critical ambiguity blocks progress. Use 2-4 meaningful options. Use multi-select only when multiple selections can all apply.",
            "parameters": {
                "type": "object",
                "properties": {
                    "question": {
                        "type": "string",
                        "description": "Question text shown to the user.",
                    },
                    "selection_mode": {
                        "type": "string",
                        "description": "single for one choice, multi for select-all-that-apply.",
                        "enum": ["single", "multi"],
                        "default": "single",
                    },
                    "options": {
                        "type": "array",
                        "description": "Available options. Keep concise and mutually exclusive when possible.",
                        "items": {
                            "type": "object",
                            "properties": {
                                "id": {
                                    "type": "string",
                                    "description": "Stable option id to return in answer.",
                                },
                                "label": {
                                    "type": "string",
                                    "description": "User-facing option label.",
                                },
                                "description": {
                                    "type": "string",
                                    "description": "Optional one-line explanation.",
                                },
                                "recommended": {
                                    "type": "boolean",
                                    "description": "Mark recommended/default option.",
                                },
                            },
                            "required": ["id", "label"],
                        },
                    },
                    "allow_other": {
                        "type": "boolean",
                        "description": "Whether user can provide custom text.",
                        "default": True,
                    },
                    "min_select": {
                        "type": "integer",
                        "description": "Minimum options user must select.",
                        "minimum": 0,
                    },
                    "max_select": {
                        "type": "integer",
                        "description": "Maximum options user can select.",
                        "minimum": 1,
                    },
                },
                "required": ["question", "options"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_session_summary",
            "description": "List every mutation made this Unity session grouped by category (scripts, materials, gameObjects, components, etc.) with a timeline. Use to answer 'what did you just do' / 'what changed' without re-reading scene state. Read-only.",
            "parameters": {
                "type": "object",
                "properties": {
                    "maxTimelineEntries": {
                        "type": "integer",
                        "description": "Max recent mutation entries to include. Default 50, max 500.",
                        "default": 50,
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "reset_eval_state",
            "description": "Per-trial reset for evaluation harnesses. Destroys non-essential root GameObjects in the active scene (keeps Main Camera + Directional Light), deletes a caller-specified glob of scripts under Assets/Scripts/ ONLY, and clears the in-memory session mutation log used by the modify_script safety gate. Intended for eval/automation use, not interactive sessions — running this against a user's working scene without their instruction would destroy unsaved work.",
            "parameters": {
                "type": "object",
                "properties": {
                    "scriptsGlob": {
                        "type": "string",
                        "description": "Comma-separated glob patterns under Assets/Scripts/ to delete (e.g. 'Assets/Scripts/ThirdPerson*.cs,Assets/Scripts/CameraFollow*.cs'). Filename glob only — '*' matches anything except path separators; '**' is not supported. Patterns OUTSIDE Assets/Scripts/ are rejected for safety. Empty (default) deletes nothing.",
                    },
                    "clearScene": {
                        "type": "boolean",
                        "description": "Destroy root GameObjects in the active scene except Main Camera + Directional Light. Default true.",
                        "default": True,
                    },
                    "clearSession": {
                        "type": "boolean",
                        "description": "Reset SessionTracker timeline so the per-trial slate is clean (relevant for safety checks like ModifyScriptTool's session-aware gate). Default true.",
                        "default": True,
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "think",
            "description": "Reason about a complex multi-step task before executing it. Use to plan what objects/assets/scripts to create, in what order (scripts before add_component), and what positions/configurations are needed. Does not modify anything.",
            "parameters": {
                "type": "object",
                "properties": {
                    "thought": {
                        "type": "string",
                        "description": "Your reasoning about the task - what needs to be done, in what order, and why",
                    }
                },
                "required": ["thought"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_scene_hierarchy",
            "description": "List GameObject paths in the active scene. Results are capped and BFS-balanced — use find_game_objects (nameContains/hasComponent/tag) or list_children to drill into a specific subtree instead of raising maxResults. For per-object components/state, follow up with get_gameobject_info or get_gameobject_components.",
            "parameters": {
                "type": "object",
                "properties": {
                    "includeInactive": {
                        "type": "boolean",
                        "description": "Include inactive objects. Default: true",
                    },
                    "maxDepth": {
                        "type": "integer",
                        "description": "Max depth to traverse (-1 for unlimited). Default: -1",
                    },
                    "rootOnly": {
                        "type": "boolean",
                        "description": "If true, only list root objects. Default: false",
                    },
                    "maxResults": {
                        "type": "integer",
                        "description": "Max objects to return. Default: 200. Use -1 for unlimited. Response includes truncated flag and totalCount when capped.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_gameobject_info",
            "description": "Get detailed information about a GameObject: position/rotation/scale, components, materials (with path and shaderName), and component-specific data (e.g., terrain data). Use to inspect properties or find a reference object's position before calculating offsets.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Name of the reference object (e.g., 'Player', 'MainCamera')",
                    }
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "find_game_objects",
            "description": "Find GameObjects in the scene by name, tag, layer, or component type. Returns a list of matching GameObject paths.",
            "parameters": {
                "type": "object",
                "properties": {
                    "nameContains": {
                        "type": "string",
                        "description": "Optional: Find objects whose name contains this substring (case-insensitive)",
                    },
                    "nameExact": {
                        "type": "string",
                        "description": "Optional: Find objects with this exact name",
                    },
                    "tag": {
                        "type": "string",
                        "description": "Optional: Find objects with this tag (e.g., 'Player', 'Enemy')",
                    },
                    "layer": {
                        "type": "string",
                        "description": "Optional: Find objects on this layer (name or index)",
                    },
                    "hasComponent": {
                        "type": "string",
                        "description": "Optional: Find objects that have this component type (e.g., 'Camera', 'Light', 'Rigidbody')",
                    },
                    "includeInactive": {
                        "type": "boolean",
                        "description": "Whether to include inactive objects. Default: false",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_selection",
            "description": "Get the currently selected GameObjects in the Unity Editor. Returns paths to all selected objects.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_selection",
            "description": "Set the Unity Editor selection to specific GameObjects by path. WARNING: This selects objects in the Project window (prefabs/assets) OR scene. If you select a prefab/asset, you CANNOT use it with tools that require scene GameObjects (like get_gameobject_info, set_transform, etc.). Only use set_selection for scene objects that exist in the hierarchy. To work with prefabs, you must instantiate them first with create_game_object or instantiate_prefab.",
            "parameters": {
                "type": "object",
                "properties": {
                    "paths": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of GameObject paths to select (must be scene objects, not prefabs)",
                    },
                    "addToSelection": {
                        "type": "boolean",
                        "description": "If true, add to current selection instead of replacing. Default: false",
                    },
                },
                "required": ["paths"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_unity_console_logs",
            "description": "Read Unity Editor runtime/play-mode console entries (Debug.Log, runtime exceptions, MonoBehaviour errors). Returns up to 2000 entries. NOT for verifying script compilation — compile_scripts already returns errorCount + per-error file/line/source-context. Calling this after a clean compile (errorCount=0) is forbidden. Valid uses: (a) compile_scripts returned errorCount>0 AND you need extra runtime context, (b) a non-compile tool returned an error you must debug, (c) the user explicitly asked to check the console / read the logs.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "refresh_asset_database",
            "description": "Refresh the AssetDatabase.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "open_scene",
            "description": "Open a scene in the editor.",
            "parameters": {
                "type": "object",
                "properties": {
                    "scenePath": {
                        "type": "string",
                        "description": "Path to the scene asset (e.g., 'Scenes/MainMenu.unity')",
                    },
                    "mode": {
                        "type": "string",
                        "enum": ["Single", "Additive"],
                        "description": "Open mode: 'Single' (replace current) or 'Additive' (add to current). Default: 'Single'",
                    },
                },
                "required": ["scenePath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "save_scene",
            "description": "Save the current active scene.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "save_scene_as",
            "description": "Save the current active scene to a new path.",
            "parameters": {
                "type": "object",
                "properties": {
                    "scenePath": {
                        "type": "string",
                        "description": "Path for the new scene file (e.g., 'Scenes/Demo/DemoScene.unity')",
                    }
                },
                "required": ["scenePath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_scene",
            "description": "Create a new scene and optionally save it.",
            "parameters": {
                "type": "object",
                "properties": {
                    "scenePath": {"type": "string"},
                    "setup": {"type": "string"},
                    "mode": {"type": "string"},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_scenes_in_build",
            "description": "List scenes in build settings.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
]
