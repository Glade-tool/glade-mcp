"""
Godot GDScript tools — file CRUD + node attachment + vetted scaffolders (8 tools).

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
                "Read a GDScript .gd file, paginated by line. GDScript source only — "
                "NOT for inspecting .tres resources (Animation, Material, etc.), scenes "
                "(.tscn), or other non-script files: for those use the matching read tool "
                "(e.g. get_animation_player_info for AnimationPlayer / Animation state, "
                "get_material_info for materials). Safe in any mode (read-only). Defaults "
                "return the first 500 lines and echo `total_lines` + `truncated` so you can "
                "request the next slice via start_line on large files instead of pulling "
                "the whole file into context. Use before modify_script to see what you're "
                "about to change."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "script_path": {
                        "type": "string",
                        "description": "res:// path to the .gd file.",
                    },
                    "start_line": {
                        "type": "integer",
                        "description": "1-indexed start line. Default 1.",
                    },
                    "end_line": {
                        "type": "integer",
                        "description": (
                            "1-indexed inclusive end line. Default 0 = until EOF or max_lines, whichever is smaller."
                        ),
                    },
                    "max_lines": {
                        "type": "integer",
                        "description": "Cap on lines returned. Default 500, clamped 1..5000.",
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
    {
        "type": "function",
        "function": {
            "name": "create_third_person_controller",
            "description": (
                "Scaffold a complete, playable 3D third-person player in ONE atomic call. "
                "ALWAYS PREFER THIS over hand-writing scripts for ANY request that wants a "
                "player that moves with WASD AND is followed by a third-person / orbit camera. "
                "It writes two VETTED, known-good GDScript files VERBATIM "
                "(third_person_controller.gd = CharacterBody3D camera-relative movement + jump; "
                "orbit_camera.gd = a decoupled mouse-orbit camera), then assembles the scene: "
                "ensures a Player (CharacterBody3D with capsule collision + mesh), a Camera3D, a "
                "ground plane, and a light; attaches both scripts; adds the Player to the 'player' "
                "group; and creates the WASD + jump input actions. "
                "Do NOT follow this with create_script / attach_script_to_node / add_input_action for "
                "the controller — it already did all of that. Why prefer it: a hand-written orbit "
                "camera almost always re-introduces a self-referential feedback loop that spins the "
                "view while strafing with A/D; the vetted template fixes that. After it runs, your "
                "only remaining step is save_scene."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "directory": {
                        "type": "string",
                        "description": ("res:// folder for the two generated scripts. Default 'res://scripts'."),
                    },
                    "player_name": {
                        "type": "string",
                        "description": (
                            "Name of the player node to create or reuse. Default 'Player'. If a "
                            "node with this name already exists it must be a CharacterBody3D."
                        ),
                    },
                    "create_ground": {
                        "type": "boolean",
                        "description": (
                            "Create a ground plane if the scene has none. Default true. Pass false "
                            "when the scene already has a floor/level."
                        ),
                    },
                    "overwrite": {
                        "type": "boolean",
                        "description": (
                            "Overwrite the generated script files if they already exist. Default "
                            "false (the tool refuses rather than clobber existing files)."
                        ),
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_2d_controller",
            "description": (
                "Scaffold a complete, playable 2D player in ONE atomic call. ALWAYS PREFER "
                "THIS over hand-writing scripts for ANY request that wants a 2D player that "
                "moves and (for platformers) jumps — a side-scroller/platformer (Mario-like) "
                "OR a top-down character (Zelda-like). It writes a VETTED, known-good "
                "CharacterBody2D GDScript VERBATIM, then assembles the scene: a Player "
                "(CharacterBody2D with a RectangleShape2D collision + a colored Polygon2D "
                "placeholder so something is visible on Play), a follow Camera2D, optionally a "
                "ground (platformer), the movement/jump input actions, and adds the Player to "
                "the 'player' group. Do NOT follow this with create_script / "
                "attach_script_to_node / add_input_action for the controller — it already did "
                "all of that. Why prefer it: the platformer template ships the game-feel "
                "details a hand-written controller almost always omits — COYOTE TIME, JUMP "
                "BUFFERING, and VARIABLE JUMP HEIGHT — so the jump feels good instead of floaty "
                "or stiff; the top-down template normalizes diagonals so they aren't faster. "
                "Replace the placeholder Polygon2D with a Sprite2D/AnimatedSprite2D for real "
                "art. After it runs, your only remaining step is save_scene. (For a 3D player "
                "use create_third_person_controller instead.)"
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "style": {
                        "type": "string",
                        "enum": ["platformer", "top_down"],
                        "description": (
                            "Movement style. 'platformer' (default) = side-view with gravity + "
                            "jump (coyote time, jump buffer, variable jump height). 'top_down' = "
                            "8-direction movement with no gravity, normalized diagonals."
                        ),
                    },
                    "directory": {
                        "type": "string",
                        "description": ("res:// folder for the generated script. Default 'res://scripts'."),
                    },
                    "player_name": {
                        "type": "string",
                        "description": (
                            "Name of the player node to create or reuse. Default 'Player'. If a "
                            "node with this name already exists it must be a CharacterBody2D."
                        ),
                    },
                    "create_ground": {
                        "type": "boolean",
                        "description": (
                            "Create a wide ground if the scene has none. Default true. Only "
                            "applies to style='platformer' (top-down has no gravity to fall onto)."
                        ),
                    },
                    "create_camera": {
                        "type": "boolean",
                        "description": (
                            "Add a follow Camera2D as a child of the Player if the scene has no Camera2D. Default true."
                        ),
                    },
                    "overwrite": {
                        "type": "boolean",
                        "description": (
                            "Overwrite the generated script file if it already exists. Default "
                            "false (the tool refuses rather than clobber an existing file)."
                        ),
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_screen_shake",
            "description": (
                "Add trauma-based screen shake to a 2D camera in ONE atomic call — the "
                "'juice' companion to create_particles_2d. PREFER THIS over hand-writing "
                "shake: it writes a VETTED Camera2D script VERBATIM and attaches it to a "
                "Camera2D (the first one in the scene, or a new one if none exists). The "
                "script is trauma-based (intensity = trauma squared, so small hits barely "
                "shake and big hits really kick), noise-driven (not cheap per-frame random), "
                "decays to zero on its own, and shakes via offset/rotation so it composes "
                "with a camera that follows the player. The script joins the 'screen_shake' "
                "group; trigger it from gameplay code wherever an impact happens (a hit, "
                "death, hard landing, or right where you emit explosion particles) with ONE "
                'line: get_tree().get_first_node_in_group("screen_shake").shake(0.5) — '
                "bigger amount (0..1) is a bigger kick. After it runs, call save_scene."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "directory": {
                        "type": "string",
                        "description": ("res:// folder for the generated script. Default 'res://scripts'."),
                    },
                    "camera_path": {
                        "type": "string",
                        "description": (
                            "Scene-relative path to the Camera2D to shake. Default: the first "
                            "Camera2D in the scene, or a new one is created if none exists."
                        ),
                    },
                    "overwrite": {
                        "type": "boolean",
                        "description": (
                            "Overwrite the generated script if it already exists. Default false "
                            "(the tool refuses rather than clobber an existing file)."
                        ),
                    },
                },
            },
        },
    },
]
