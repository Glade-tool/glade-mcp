"""
Godot GDScript tools — file CRUD + node attachment + vetted scaffolders (16 tools).

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
            "name": "find_references",
            "description": (
                "Find every .gd script that references a symbol (a class_name, func, "
                "or var name), with per-file line context. Matches whole identifiers "
                "only (so 'Player' does NOT match 'PlayerController'), unlike a raw "
                "substring search. Call this BEFORE renaming or changing a symbol other "
                "scripts may use — it reveals the dependent scripts a change would break "
                "so you can update them too. Returns files ordered by reference count."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "symbol": {
                        "type": "string",
                        "description": "The identifier to find references to — a class_name, func, or var name (e.g. 'PlayerController', 'take_damage', 'max_health').",
                    },
                    "max_files": {
                        "type": "integer",
                        "description": "Max distinct files to return (1-100). Default 40.",
                    },
                    "max_matches_per_file": {
                        "type": "integer",
                        "description": "Max line snippets per file (1-50). Default 5. The per-file count is always exact even when snippets are capped.",
                    },
                },
                "required": ["symbol"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "find_scene_usages",
            "description": (
                "Find every .tscn scene that references a resource (a .gd script or a "
                ".tscn scene) via an [ext_resource] entry — the scene-wiring counterpart "
                "to find_references (which covers code). Use it to see the blast radius "
                "BEFORE renaming, moving, or deleting a script or scene: which scenes "
                "attach the script to a node, or instance the scene as a sub-scene. That "
                "wiring lives in scene data, not code, so find_references won't show it. "
                "Each usage reports ref_type ('Script', 'PackedScene', ...)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "resource_path": {
                        "type": "string",
                        "description": "res:// path to the .gd script or .tscn scene whose scene references you want (e.g. 'res://scripts/player.gd').",
                    },
                    "max_results": {
                        "type": "integer",
                        "description": "Max referencing scenes to return (1-200). Default 60.",
                    },
                },
                "required": ["resource_path"],
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
    {
        "type": "function",
        "function": {
            "name": "create_juice",
            "description": (
                "Attach a reusable 'juice' tween component to a Node2D/Control in ONE "
                "atomic call — the PER-OBJECT companion to create_screen_shake (which "
                "kicks the whole camera). PREFER THIS over hand-writing tweens for any "
                "'make it feel good/pop/punchy' request: a scale pop when a coin is "
                "collected, a hit flash when something takes damage, a fade on "
                "spawn/despawn, or a gentle idle loop that makes a pickup catch the eye. "
                "It writes a VETTED tween script and parents a 'Juice' node UNDER the "
                "target, tweening the target's scale/modulate from the outside — so it "
                "never clobbers the target's own script. The script caches the resting "
                "scale/modulate, centers a Control's pivot, and uses BACK/ELASTIC easing "
                "so a pop actually pops. Trigger the feel from the target's script (or "
                "any reference): $Juice.pop() on a pickup/land/click, "
                "$Juice.flash(Color.RED) on a hit, $Juice.fade_out(0.3) to despawn (it "
                "emits faded_out so you can queue_free). The shared juice.gd is written "
                "once and reused across many targets. 2D-only (needs a CanvasItem). "
                "After it runs, call save_scene."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "target_path": {
                        "type": "string",
                        "description": (
                            "Scene-relative path of the Node2D or Control to juice (e.g. a "
                            "Sprite2D, AnimatedSprite2D, a coin, the player)."
                        ),
                    },
                    "name": {
                        "type": "string",
                        "description": "Name of the Juice child node (how you address it: $Name.pop()). Default 'Juice'.",
                    },
                    "idle": {
                        "type": "string",
                        "description": (
                            "Ambient loop that plays automatically at runtime: 'none' "
                            "(default), 'pulse' (gentle scale breathe — great for pickups), "
                            "or 'bob' (vertical hover, Node2D only)."
                        ),
                        "enum": ["none", "pulse", "bob"],
                    },
                    "spawn": {
                        "type": "string",
                        "description": (
                            "On-ready effect: 'pop_in' (default — scales up from nothing "
                            "when the node spawns) or 'none'."
                        ),
                        "enum": ["none", "pop_in"],
                    },
                    "directory": {
                        "type": "string",
                        "description": "res:// folder for the generated juice.gd. Default 'res://scripts'.",
                    },
                    "overwrite": {
                        "type": "boolean",
                        "description": (
                            "Rewrite juice.gd even if it exists. Default false (reuses the "
                            "existing shared script — attach Juice to many nodes without rewriting)."
                        ),
                    },
                },
                "required": ["target_path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_scene_transition",
            "description": (
                "Register a full-screen scene-transition overlay as an AUTOLOAD in ONE "
                "atomic call — the piece that turns hard scene CUTS into smooth fades "
                "(menu<->game, level<->level, on death/respawn). PREFER THIS over "
                "hand-writing transitions: it writes a VETTED GDScript VERBATIM and "
                "registers it as a project autoload (default name 'ScreenTransition'). It "
                "MUST be a singleton to work — a per-scene node is freed by "
                "change_scene_to_file mid-transition, so its fade-in never runs. Reach it "
                "globally by name (no node/group lookup): "
                "ScreenTransition.transition_to('res://scenes/level_2.tscn') fades out, "
                "swaps the scene, fades back in (use this in place of a bare "
                "get_tree().change_scene_to_file in menu/pause/win logic); "
                "await ScreenTransition.fade_out() covers the screen; "
                "ScreenTransition.flash(Color.RED) does a quick hit blink. The overlay is a "
                "top-most CanvasLayer that clears a paused tree before swapping. It "
                "activates on the next play — nothing is added to the current scene, so NO "
                "save_scene is needed."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "singleton_name": {
                        "type": "string",
                        "description": (
                            "Autoload (global) name you call it by. Must be a valid "
                            "identifier. Default 'ScreenTransition'."
                        ),
                    },
                    "color": {
                        "type": "string",
                        "description": "Fade color, '#rrggbb[aa]' or 'r,g,b[,a]'. Default black.",
                    },
                    "duration": {
                        "type": "number",
                        "description": ("Default fade time in seconds for each half of a transition. Default 0.4."),
                    },
                    "directory": {
                        "type": "string",
                        "description": "res:// folder for the generated screen_transition.gd. Default 'res://scripts'.",
                    },
                    "overwrite": {
                        "type": "boolean",
                        "description": (
                            "Rewrite screen_transition.gd even if it exists. Default false "
                            "(reuses the existing script; color/duration apply only with overwrite=true)."
                        ),
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_game_manager",
            "description": (
                "Drop the HUB of a simple 2D game into the scene in ONE atomic call — the "
                "piece that turns a playable character into a winnable/losable GAME. PREFER "
                "THIS over hand-writing game-state code: it writes a VETTED GDScript VERBATIM "
                "and builds a GameManager node plus a HUD (CanvasLayer with score + lives "
                "readouts and a centered win/lose banner). It tracks score and lives, RESPAWNS "
                "the player (first node in the 'player' group) on a non-fatal hit, and ends the "
                "game on win/lose. The manager joins the 'game_manager' group; gameplay reaches "
                "it without a reference: add_score(1) on a pickup, lose_life() on a hit, win() "
                "at a goal. Pair it with create_collectible (pickups) and create_hazard "
                "(dangers), which already call these methods. One manager per scene (the tool "
                "refuses a second). After it runs, call save_scene."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "directory": {
                        "type": "string",
                        "description": ("res:// folder for the generated script. Default 'res://scripts'."),
                    },
                    "manager_name": {
                        "type": "string",
                        "description": "Name for the manager node. Default 'GameManager'.",
                    },
                    "starting_lives": {
                        "type": "integer",
                        "description": "Lives the player starts with. Default 3.",
                    },
                    "score_to_win": {
                        "type": "integer",
                        "description": (
                            "Score that triggers an automatic win (e.g. 10 to 'collect 10 "
                            "coins'). Default 0, which means the game is won by collecting "
                            "EVERY collectible in the level (collect-them-all) — so a coins "
                            "game is winnable without setting this. Set it only for an "
                            "explicit numeric target; a level with no collectibles stays a "
                            "manual win() (e.g. from a goal)."
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
    {
        "type": "function",
        "function": {
            "name": "create_collectible",
            "description": (
                "Add a COLLECTIBLE (coin / pickup / star) to the scene in ONE atomic call. "
                "PREFER THIS over hand-writing a pickup: it writes a VETTED Area2D script "
                "VERBATIM (written once per project, reused on every call) and builds the node "
                "with a collision shape + a visible diamond placeholder. On player touch it "
                "calls the GameManager's add_score(value) and frees itself, so call "
                "create_game_manager FIRST or the pickup vanishes without scoring. Place many "
                "by calling this repeatedly or via duplicate_node. The node joins the "
                "'collectibles' group. After it runs, call save_scene."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "directory": {
                        "type": "string",
                        "description": ("res:// folder for the generated script. Default 'res://scripts'."),
                    },
                    "name": {
                        "type": "string",
                        "description": "Node name. Default 'Collectible'.",
                    },
                    "parent_path": {
                        "type": "string",
                        "description": ("Scene-relative parent path. Default: the scene root."),
                    },
                    "position": {
                        "type": "string",
                        "description": "Placement as 'x,y' (pixels). Default '0,0'.",
                    },
                    "value": {
                        "type": "integer",
                        "description": "Score added when picked up. Default 1.",
                    },
                    "radius": {
                        "type": "number",
                        "description": ("Collision + placeholder radius in pixels. Default 12."),
                    },
                    "color": {
                        "type": "string",
                        "description": ("Placeholder fill color (name or 'r,g,b'). Default gold."),
                    },
                    "overwrite": {
                        "type": "boolean",
                        "description": (
                            "Regenerate the shared collectible script if it already exists. Default false."
                        ),
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_hazard",
            "description": (
                "Add a HAZARD (spikes / lava / an enemy hurtbox) to the scene in ONE atomic "
                "call — the threat that makes the level losable. PREFER THIS over hand-writing "
                "a damage volume: it writes a VETTED Area2D script VERBATIM (written once per "
                "project, reused on every call) and builds the node with a collision shape + a "
                "red placeholder. On player touch it calls the GameManager's lose_life (which "
                "respawns the player or ends the game), so call create_game_manager FIRST or "
                "contact does nothing. Place many by calling this repeatedly or via "
                "duplicate_node; pair it with create_screen_shake for a hit that feels like "
                "one. The node joins the 'hazards' group. After it runs, call save_scene."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "directory": {
                        "type": "string",
                        "description": ("res:// folder for the generated script. Default 'res://scripts'."),
                    },
                    "name": {
                        "type": "string",
                        "description": "Node name. Default 'Hazard'.",
                    },
                    "parent_path": {
                        "type": "string",
                        "description": ("Scene-relative parent path. Default: the scene root."),
                    },
                    "position": {
                        "type": "string",
                        "description": "Placement as 'x,y' (pixels). Default '0,0'.",
                    },
                    "size": {
                        "type": "string",
                        "description": ("Collision + placeholder size as 'w,h' (pixels). Default '48,16'."),
                    },
                    "color": {
                        "type": "string",
                        "description": ("Placeholder fill color (name or 'r,g,b'). Default danger red."),
                    },
                    "overwrite": {
                        "type": "boolean",
                        "description": ("Regenerate the shared hazard script if it already exists. Default false."),
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_enemy_2d",
            "description": (
                "Add a moving ENEMY (a goomba / patrolling guard / chaser) to the scene in ONE "
                "atomic call — the threat that walks the level, hurts the player, and can be "
                "DEFEATED by stomping on its head. PREFER THIS over create_hazard when the danger "
                "should MOVE or be beatable (create_hazard is a STATIC damage volume). It writes a "
                "VETTED CharacterBody2D script VERBATIM (written once per project, reused on every "
                "call) and builds the node with a body collision shape, a placeholder, and a "
                "Hurtbox. Two outcomes by where the player hits it: a STOMP (player drops onto its "
                "head) kills it, adds score_value via the GameManager, and bounces the player; a "
                "SIDE/below touch calls the GameManager's lose_life (which respawns the player or "
                "ends the game) — so call create_game_manager FIRST or contact does nothing. "
                "style='patrol' walks back and forth, turning at walls AND ledges; style='chaser' "
                "homes in on the player when within aggro_range (through walls); style='guard' "
                "patrols until it SEES the player (forward vision cone + clear line of sight, so "
                "walls hide the player), gives chase, and gives up when it loses sight — the "
                "classic alert-and-pursue guard. Place many by calling this "
                "repeatedly or via duplicate_node; pair it with create_screen_shake for a stomp "
                "that feels like one. The node joins the 'enemies' group. After it runs, call "
                "save_scene."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "directory": {
                        "type": "string",
                        "description": ("res:// folder for the generated script. Default 'res://scripts'."),
                    },
                    "name": {
                        "type": "string",
                        "description": "Node name. Default 'Enemy'.",
                    },
                    "parent_path": {
                        "type": "string",
                        "description": ("Scene-relative parent path. Default: the scene root."),
                    },
                    "position": {
                        "type": "string",
                        "description": "Placement as 'x,y' (pixels). Default '0,0'.",
                    },
                    "style": {
                        "type": "string",
                        "enum": ["patrol", "chaser", "guard"],
                        "description": (
                            "'patrol' (default) walks back and forth, turning at walls and ledges. "
                            "'chaser' homes in on the player when within aggro_range (sees through walls). "
                            "'guard' patrols until it SEES the player (forward vision cone + clear line "
                            "of sight — walls block it), then chases and gives up after losing sight. "
                            "Vision range/cone/give-up are inspector-tunable exports."
                        ),
                    },
                    "size": {
                        "type": "string",
                        "description": ("Body + placeholder size as 'w,h' (pixels). Default '28,32'."),
                    },
                    "speed": {
                        "type": "number",
                        "description": "Horizontal move speed in px/s. Default 70.",
                    },
                    "score_value": {
                        "type": "integer",
                        "description": ("Score added when the player stomps this enemy. Default 1."),
                    },
                    "color": {
                        "type": "string",
                        "description": ("Placeholder fill color (name or 'r,g,b'). Default menacing purple."),
                    },
                    "overwrite": {
                        "type": "boolean",
                        "description": ("Regenerate the shared enemy script if it already exists. Default false."),
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_enemy_3d",
            "description": (
                "Add a moving ENEMY to a 3D scene (Node3D root) in ONE atomic call — the 3D "
                "analog of create_enemy_2d: a CharacterBody3D threat that walks the level, "
                "hurts the player, and can be DEFEATED by stomping on its head (the classic "
                "3D-platformer stomp). USE THIS over create_enemy_2d when the open scene is 3D "
                "(create_enemy_2d refuses to run in a 3D scene, and this one refuses in a 2D "
                "scene). It writes a VETTED CharacterBody3D script VERBATIM (written once per "
                "project, reused on every call) and builds the node with a capsule collision "
                "shape, a placeholder mesh, and a Hurtbox. Two outcomes by where the player "
                "hits it: a STOMP (player drops onto its head) kills it, adds score_value via "
                "the GameManager, and bounces the player; a SIDE/below touch calls lose_life. "
                "style='patrol' walks back and forth along X, turning at walls AND ledges; "
                "style='chaser' homes in on the player on the XZ plane within aggro_range "
                "(through walls); style='guard' patrols until it SEES the player (forward "
                "vision cone + clear line of sight, so walls hide the player), gives chase, and "
                "gives up when it loses sight. pathfinding='navmesh' makes a chaser/guard PATH "
                "AROUND obstacles via a NavigationAgent3D instead of walking straight at the "
                "player — bake a NavigationRegion3D first with bake_navigation_mesh (this is how "
                "you get a true 'enemy chases the player across the navmesh'). NOTE: "
                "create_game_manager is 2D-only, so in a "
                "pure-3D scene scoring/lives stay inert until a node joins the 'game_manager' "
                "group exposing add_score/lose_life — the movement + stomp/contact logic works "
                "regardless. Ensure the player is in the 'player' group. Place many by calling "
                "this repeatedly or via duplicate_node. The node joins the 'enemies' group. "
                "After it runs, call save_scene."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "directory": {
                        "type": "string",
                        "description": ("res:// folder for the generated script. Default 'res://scripts'."),
                    },
                    "name": {
                        "type": "string",
                        "description": "Node name. Default 'Enemy'.",
                    },
                    "parent_path": {
                        "type": "string",
                        "description": ("Scene-relative parent path. Default: the scene root."),
                    },
                    "position": {
                        "type": "string",
                        "description": "Placement as 'x,y,z' (meters). Default '0,0,0'.",
                    },
                    "style": {
                        "type": "string",
                        "enum": ["patrol", "chaser", "guard"],
                        "description": (
                            "'patrol' (default) walks back and forth along X, turning at walls and ledges. "
                            "'chaser' homes in on the player on the XZ plane within aggro_range (sees "
                            "through walls). 'guard' patrols until it SEES the player (forward vision cone "
                            "+ clear line of sight — walls block it), then chases and gives up after losing "
                            "sight. Vision range/cone/give-up are inspector-tunable exports."
                        ),
                    },
                    "pathfinding": {
                        "type": "string",
                        "enum": ["direct", "navmesh"],
                        "description": (
                            "How chaser/guard pursue. 'direct' (default) walks straight at the player. "
                            "'navmesh' adds a NavigationAgent3D so the enemy paths AROUND obstacles — "
                            "requires a baked NavigationRegion3D (call bake_navigation_mesh). Ignored for "
                            "'patrol' (it never pursues)."
                        ),
                    },
                    "speed": {
                        "type": "number",
                        "description": "Move speed in m/s. Default 2.5.",
                    },
                    "score_value": {
                        "type": "integer",
                        "description": ("Score added when the player stomps this enemy. Default 1."),
                    },
                    "color": {
                        "type": "string",
                        "description": ("Placeholder mesh color (name or 'r,g,b'). Default menacing purple."),
                    },
                    "overwrite": {
                        "type": "boolean",
                        "description": ("Regenerate the shared enemy script if it already exists. Default false."),
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_projectile",
            "description": (
                "Give a node the ability to SHOOT in ONE atomic call — the combat verb that "
                "pairs with create_enemy_2d/3d. PREFER THIS over hand-wiring a bullet system "
                "for any 'shoot / fire / launch a projectile' request. Dimension-aware: "
                "space='2d'|'3d' (inferred from the open scene's root when omitted) — 2D builds "
                "an Area2D projectile + Node2D shooter, 3D an Area3D + Node3D. It writes TWO "
                "VETTED scripts VERBATIM (once per project, reused on every call): a PROJECTILE "
                "that flies straight along its aim, damages the first node in target_group "
                "(default 'enemies') it overlaps — calling take_damage(amount) if present, else "
                "freeing the target (a destroy-on-hit fallback so it works before a health "
                "system exists) — and self-frees on hit or after lifetime; and a SHOOTER added "
                "as a CHILD of the target (it can't replace the player's existing controller "
                "script) that spawns a projectile on the input_action, respecting cooldown. The "
                "shooter is parented to the 'player'-group node by default (or shooter_path, or "
                "the scene root). Registers input_action (default 'shoot') bound to key (default "
                "'mouse_left' — click to shoot). 2D aims at the mouse by default; 3D aims along "
                "the shooter's forward (-Z). Projectiles join the 'projectiles' group. Pair with "
                "create_particles_2d/3d for an impact burst. After it runs, call save_scene."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "space": {
                        "type": "string",
                        "enum": ["2d", "3d"],
                        "description": ("Dimension. Default: inferred from the open scene's root node."),
                    },
                    "shooter_path": {
                        "type": "string",
                        "description": (
                            "Node the Shooter is parented to. Default: the 'player'-group node if one "
                            "exists, else the scene root."
                        ),
                    },
                    "name": {
                        "type": "string",
                        "description": "Shooter node name. Default 'Shooter'.",
                    },
                    "input_action": {
                        "type": "string",
                        "description": "InputMap action that fires. Default 'shoot'.",
                    },
                    "key": {
                        "type": "string",
                        "description": (
                            "Binding for the action: 'mouse_left' (default), 'mouse_right', "
                            "'mouse_middle', or a keyboard key name ('J', 'Space', ...)."
                        ),
                    },
                    "aim": {
                        "type": "string",
                        "description": (
                            "Travel direction. 2D: 'mouse' (default), 'right', 'left', 'up', 'down'. "
                            "3D: 'forward' (default), 'back', 'left', 'right', 'up', 'down' (relative "
                            "to the shooter's facing)."
                        ),
                    },
                    "speed": {
                        "type": "number",
                        "description": "Projectile speed. Default 600 (2D, px/s) / 24 (3D, m/s).",
                    },
                    "damage": {
                        "type": "integer",
                        "description": "Damage dealt to a hit target. Default 1.",
                    },
                    "lifetime": {
                        "type": "number",
                        "description": ("Seconds before a projectile frees itself. Default 2 (2D) / 3 (3D)."),
                    },
                    "cooldown": {
                        "type": "number",
                        "description": "Minimum seconds between shots. Default 0.25.",
                    },
                    "radius": {
                        "type": "number",
                        "description": "Projectile size. Default 6 (2D, px) / 0.15 (3D, m).",
                    },
                    "color": {
                        "type": "string",
                        "description": ("Projectile placeholder color (name or 'r,g,b'). Default warm yellow."),
                    },
                    "target_group": {
                        "type": "string",
                        "description": "Group a projectile damages. Default 'enemies'.",
                    },
                    "directory": {
                        "type": "string",
                        "description": ("res:// folder for the generated scripts. Default 'res://scripts'."),
                    },
                    "overwrite": {
                        "type": "boolean",
                        "description": (
                            "Regenerate the shared projectile/shooter scripts if they exist. Default false."
                        ),
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_health",
            "description": (
                "Give a node HIT POINTS in ONE atomic call — the other half of the combat "
                "loop (pairs with create_projectile / create_enemy_2d/3d). PREFER THIS over "
                "hand-writing an HP script for any 'health / hit points / takes N hits / can "
                "be damaged / dies after' request. It writes a VETTED, reusable Health script "
                "VERBATIM (once per project) and attaches it as a CHILD node named 'Health' of "
                "the target (a child because a Godot node holds one script and the target "
                "usually already has one; the component is pure logic so the SAME script works "
                "in 2D and 3D). The component exposes take_damage(amount), heal(amount), "
                "get_health(), is_alive(), with @export max_health + invuln_seconds + "
                "free_owner_on_death, and emits 'damaged'/'healed'/'died'. It composes "
                "AUTOMATICALLY with create_projectile: a projectile looks for a 'Health' child "
                "on what it hits and routes damage there, so adding Health to an enemy turns "
                "one-shot-destroy into real multi-hit HP. Other sources call "
                "$Health.take_damage(n). free_owner_on_death=true (default) frees the parent at "
                "0 HP — right for enemies/destructibles; for the PLAYER pass false and handle "
                "'died' (respawn / game over) plus invuln_seconds for i-frames. KEEP the name "
                "'Health' so the projectile lookup works. After it runs, call save_scene."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "target_path": {
                        "type": "string",
                        "description": (
                            "Node to attach Health to (an enemy, a destructible, the player). "
                            "Default: the 'player'-group node if one exists, else REQUIRED."
                        ),
                    },
                    "name": {
                        "type": "string",
                        "description": (
                            "Component node name. Default 'Health' — keep it so the projectile auto-lookup finds it."
                        ),
                    },
                    "max_health": {
                        "type": "integer",
                        "description": "Maximum (and starting) hit points. Default 3.",
                    },
                    "invuln_seconds": {
                        "type": "number",
                        "description": (
                            "Invulnerability window after a hit (i-frames). Default 0 (every hit "
                            "lands). Set ~0.5 for a player."
                        ),
                    },
                    "free_owner_on_death": {
                        "type": "boolean",
                        "description": (
                            "Free the parent entity at 0 HP. Default true (enemies/destructibles). "
                            "Set false for the player and handle 'died' yourself."
                        ),
                    },
                    "directory": {
                        "type": "string",
                        "description": ("res:// folder for the generated script. Default 'res://scripts'."),
                    },
                    "overwrite": {
                        "type": "boolean",
                        "description": ("Regenerate the shared health script if it exists. Default false."),
                    },
                },
            },
        },
    },
]
