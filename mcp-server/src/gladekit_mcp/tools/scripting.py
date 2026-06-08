"""
Scripting category tools — C# scripts, assets, folders, ScriptableObjects.
"""

from typing import Dict, List

CATEGORY = {
    "name": "scripting",
    "display_name": "Scripting & Assets",
    "keywords": [
        "script",
        "code",
        "class",
        "c#",
        "csharp",
        "asset",
        "folder",
        "file",
        "scriptable",
        "monobehaviour",
        "shader",
        "compute",
    ],
}

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "create_script",
            "description": "Create a new text-based asset file (.cs, .shader, .compute, .hlsl, etc.). Extension determines asset type. Use when the file does NOT exist; use modify_script if it already exists. IMPORTANT: After creating a .cs script, you MUST call compile_scripts and wait for status='idle' BEFORE calling add_component with the new type — otherwise the type won't be found. SAFETY: the bridge refuses create_script when the target path already exists on disk and was not created in this session via create_script, unless confirmExistingFileModification=true is set. Set the flag ONLY when the user explicitly named the file to regenerate or replace. Otherwise pick a different path — never silently clobber existing user code.",
            "parameters": {
                "type": "object",
                "properties": {
                    "scriptPath": {
                        "type": "string",
                        "description": "Path relative to Assets folder with file extension (e.g., 'Scripts/MyScript.cs', 'Shaders/MyShader.shader', 'Shaders/MyCompute.compute'). The extension determines the asset type. Will create the directory if needed. Default to 'Scripts/' if no specific path is provided. Follow the project's existing folder structure when possible.",
                    },
                    "scriptContent": {
                        "type": "string",
                        "description": "Complete file content. For .cs files: C# script code with all required using statements, null checks, and proper Unity patterns. For .shader files: HLSL/CG shader code with Shader declaration, Properties, SubShader, and Pass blocks. For other file types: appropriate content for that asset type.",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set to true ONLY when the user explicitly named the file to regenerate or replace (e.g. 'rewrite PlayerController.cs from scratch'). Required for any create_script call whose target path already exists and was not created via create_script in the current session. Defaults to false. Setting this without explicit user authorization risks clobbering real project code.",
                    },
                },
                "required": ["scriptPath", "scriptContent"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_third_person_controller",
            "description": "ALWAYS use this — not create_script — for ANY request that wants a player that (a) moves with WASD/arrow keys AND (b) jumps AND (c) is followed by a camera, INCLUDING when the player is one of several systems being scaffolded in the same turn (e.g. 'build a player + an enemy + collectibles'). Hand-written third-person controllers reliably ship two runtime bugs the playability probe catches automatically: a self-referential camera offset that makes the player walk in circles, and a fragile collision-callback isGrounded that kills the jump. This tool is ATOMIC and does the whole setup for you: it copies two vetted, Play-tested scripts VERBATIM (ThirdPersonController.cs — CharacterController movement + grounded jump, camera-relative input; FollowCamera.cs — modern mouse/right-stick orbit camera), ensures a Player capsule and a Main Camera exist, adds CharacterController to the Player, and attaches ThirdPersonController + FollowCamera automatically as soon as the scripts compile. After it returns, your ONLY remaining step is to call compile_scripts and wait for status='idle' — do NOT call add_component for the controller, the follow camera, or the character controller (the tool already handled all three), and no object-reference wiring is needed (the scripts self-resolve: ThirdPersonController → Camera.main, FollowCamera → the 'Player' tag). Use create_script ONLY for non-third-person controllers (2D platformer, top-down, twin-stick) — no template exists for those yet.",
            "parameters": {
                "type": "object",
                "properties": {
                    "directory": {
                        "type": "string",
                        "description": "Folder (relative to Assets) to write the two scripts into. Defaults to 'Scripts'. Filenames are fixed (ThirdPersonController.cs, FollowCamera.cs) because Unity requires the MonoBehaviour class name to match the file name.",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set to true ONLY when the user explicitly asked to regenerate/replace an existing controller. Required if either target file already exists and was not created in this session. Defaults to false — otherwise pass a different 'directory' so you don't clobber existing user code.",
                    },
                    "playerName": {
                        "type": "string",
                        "description": "Name of the player GameObject to attach the controller to. Defaults to 'Player'. If a GameObject with this name (or the 'Player' tag) already exists it is reused; otherwise a Capsule with this name is created at (0,1,0) and tagged 'Player'.",
                    },
                    "createGround": {
                        "type": "boolean",
                        "description": "Whether to create a ground plane when the scene has no floor-like object. Defaults to true so a standalone call yields a player that can stand. Set false if you are building the level yourself or have already created ground.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "modify_script",
            "description": "Modify an existing text-based asset file (.cs, .shader, .compute, etc.). File MUST exist in the project — verify in Unity context first. Provide the complete file content including all existing code. SAFETY: the bridge refuses modify_script against scripts the agentic loop did NOT create in this session unless confirmExistingFileModification=true is set. Set the flag ONLY when the user explicitly named the file (e.g. 'update PlayerMovement.cs') or used language like 'extend' / 'modify the existing X'. Absent that signal, do NOT set the flag and do NOT call modify_script — call create_script with a new path for fresh-scaffold prompts.",
            "parameters": {
                "type": "object",
                "properties": {
                    "scriptPath": {
                        "type": "string",
                        "description": "Path relative to Assets folder with file extension (e.g., 'Scripts/MyScript.cs', 'Shaders/MyShader.shader'). MUST match exactly a path shown in the Unity context. If the file is not listed in context, it doesn't exist - use create_script instead. Follow the project's existing folder structure.",
                    },
                    "scriptContent": {
                        "type": "string",
                        "description": "Complete modified file content. MUST include ALL existing code from the context, then ADD your changes. Never remove existing fields, methods, or functionality. For .cs files: complete C# script code. For .shader files: complete HLSL/CG shader code.",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set to true ONLY when the user explicitly named the file to extend or modify (e.g. 'update PlayerMovement.cs', 'extend the existing HealthSystem'). Required for any modify_script against a script not created via create_script in the current session. Defaults to false. Setting this without explicit user authorization risks corrupting real project code.",
                    },
                },
                "required": ["scriptPath", "scriptContent"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_script_content",
            "description": "Read the full content of a text-based asset file by path (e.g., 'Assets/Scripts/PlayerMovement.cs', 'Assets/Shaders/MyShader.shader'). Supports .cs (C# scripts), .shader (HLSL/CG shaders), .compute (compute shaders), .hlsl, .cginc, and other text-based Unity assets. Use this when the user asks to fix or update a specific script or shader.",
            "parameters": {
                "type": "object",
                "properties": {
                    "scriptPath": {
                        "type": "string",
                        "description": "Path to the file with extension (relative to Assets, e.g., 'Scripts/MyScript.cs' or 'Shaders/MyShader.shader').",
                    }
                },
                "required": ["scriptPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "find_scripts",
            "description": "Find scripts by name (returns script paths). Use when you need to locate a script by partial name before reading it.",
            "parameters": {
                "type": "object",
                "properties": {
                    "nameContains": {
                        "type": "string",
                        "description": "Substring to match script file names.",
                    },
                    "maxResults": {
                        "type": "integer",
                        "description": "Max results (1-100). Default: 20",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_scripts",
            "description": "Full-text grep across all script CONTENTS for a literal substring (e.g., 'NavMeshAgent', 'OnTriggerEnter', 'speed = '). Returns script paths whose source contains the query. Use ONLY for content search. Do NOT use for: (a) finding scripts by file/class name — use find_scripts; (b) looking up names of other tools or APIs; (c) generic 'find me X' fallbacks. If find_scripts already returned results, do not also call search_scripts for the same target.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Text to search for in scripts.",
                    },
                    "maxResults": {
                        "type": "integer",
                        "description": "Max results (1-100). Default: 10",
                    },
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "compile_scripts",
            "description": "Check Unity script compilation status. Call this after create_script or modify_script. Returns isCompiling (bool) and status ('compiling' or 'idle'). If still compiling, call again. When compilation finishes with errors, returns hasErrors=true plus each error's file path, line number, and ±10 lines of source context — use that context to fix the script before retrying.",
            "parameters": {
                "type": "object",
                "properties": {},
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_folder",
            "description": "Create a folder in the Assets directory. Creates parent folders if needed.",
            "parameters": {
                "type": "object",
                "properties": {
                    "folderPath": {
                        "type": "string",
                        "description": "Path relative to Assets folder (e.g., 'Prefabs/Enemies' creates Assets/Prefabs/Enemies)",
                    }
                },
                "required": ["folderPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "move_asset",
            "description": "Move an asset to a new location in the project.",
            "parameters": {
                "type": "object",
                "properties": {
                    "sourcePath": {
                        "type": "string",
                        "description": "Current path of the asset (e.g., 'Materials/Old/MyMaterial.mat')",
                    },
                    "destinationPath": {
                        "type": "string",
                        "description": "New path for the asset (e.g., 'Materials/New/MyMaterial.mat')",
                    },
                },
                "required": ["sourcePath", "destinationPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "duplicate_asset",
            "description": "Duplicate an asset in the project.",
            "parameters": {
                "type": "object",
                "properties": {
                    "sourcePath": {
                        "type": "string",
                        "description": "Path of the asset to duplicate",
                    },
                    "destinationPath": {
                        "type": "string",
                        "description": "Path for the duplicate (if not provided, adds '_copy' suffix)",
                    },
                },
                "required": ["sourcePath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "delete_asset",
            "description": "Delete an asset from the project. Use with caution!",
            "parameters": {
                "type": "object",
                "properties": {
                    "assetPath": {
                        "type": "string",
                        "description": "Path of the asset to delete",
                    }
                },
                "required": ["assetPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_assets",
            "description": "List assets in the project by type and/or name filter. Use nameContains to narrow results. Returns filenames in message.",
            "parameters": {
                "type": "object",
                "properties": {
                    "assetType": {
                        "type": "string",
                        "description": "Type filter: 'Material', 'Prefab', 'Texture', 'AudioClip', 'AnimationClip', 'AnimatorController', 'Scene', 'Script', or 'All'",
                    },
                    "nameContains": {
                        "type": "string",
                        "description": "Optional: Filter by name containing this string (RECOMMENDED to narrow results)",
                    },
                    "folderPath": {
                        "type": "string",
                        "description": "Optional: Limit search to this folder (e.g., 'Prefabs/Enemies')",
                    },
                    "maxResults": {
                        "type": "integer",
                        "description": "Optional: Max results. Default: 20, Max: 50",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_scriptable_object",
            "description": "Create a ScriptableObject asset from a script class. The script must inherit from ScriptableObject and be compiled. Use this to create data assets like PetDefinition, ItemData, GameSettings, etc. The asset path should end with .asset (e.g., 'Assets/Content/Pets/Definitions/Pet_Mossi.asset').",
            "parameters": {
                "type": "object",
                "properties": {
                    "assetPath": {
                        "type": "string",
                        "description": "Path where the ScriptableObject asset will be created (e.g., 'Assets/Content/Pets/Definitions/Pet_Mossi.asset'). The .asset extension will be added if missing.",
                    },
                    "scriptTypeName": {
                        "type": "string",
                        "description": "Name of the ScriptableObject class (e.g., 'PetDefinition', 'ItemData'). Can be just the class name or fully qualified (e.g., 'MyNamespace.PetDefinition'). The script must exist and inherit from ScriptableObject.",
                    },
                },
                "required": ["assetPath", "scriptTypeName"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_scriptable_object_property",
            "description": "Set a property on a ScriptableObject asset. Supports primitives, Vector3/Color/Quaternion, enums (provide enum name as string), and asset references (provide asset path). For List<T>/arrays, use appendToList=true to append instead of replace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "assetPath": {
                        "type": "string",
                        "description": "Path to the ScriptableObject asset (e.g., 'Assets/Content/Pets/Definitions/Pet_Mossi.asset')",
                    },
                    "propertyName": {
                        "type": "string",
                        "description": "Name of the property or field to set (e.g., 'PetId', 'DisplayName', 'Portrait', 'Prefab', 'petDefinitions', 'myEnumField'). For enum dropdowns, provide the enum name. For lists, use appendToList=true to append items.",
                    },
                    "value": {
                        "type": "string",
                        "description": "Value to set (will be converted to appropriate type). For enums (dropdowns), provide the enum value name as a string (e.g., 'MyEnumValue'). For asset references, provide the asset path. For lists with appendToList=true, can be a single item or JSON array like '[item1, item2]'.",
                    },
                    "appendToList": {
                        "type": "boolean",
                        "description": "If true and the property is a List<T> or array, append the value(s) to the existing list instead of replacing it. This safely preserves existing items and supports undo/redo. Default: false.",
                        "default": False,
                    },
                },
                "required": ["assetPath", "propertyName", "value"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "check_asset_exists",
            "description": "Check if an asset exists at a path (case-insensitive). Returns similar paths if not found. When false, immediately call the corresponding create tool in the same response — this is a verification step, not a stopping point.",
            "parameters": {
                "type": "object",
                "properties": {
                    "assetPath": {
                        "type": "string",
                        "description": "Path relative to Assets folder (e.g., 'Materials/MyMaterial.mat', 'Prefabs/Cube.prefab', 'Textures/Logo.png')",
                    }
                },
                "required": ["assetPath"],
            },
        },
    },
]
