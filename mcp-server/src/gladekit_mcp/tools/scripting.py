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
            "description": "ALWAYS use this — not create_script — for ANY request that wants a player that (a) moves with WASD/arrow keys AND (b) jumps AND (c) is followed by a camera, INCLUDING when the player is one of several systems being scaffolded in the same turn (e.g. 'build a player + an enemy + collectibles'). Hand-written third-person controllers reliably ship two runtime bugs the playability probe catches automatically: a self-referential camera offset that makes the player walk in circles, and a fragile collision-callback isGrounded that kills the jump. This tool is ATOMIC and does the whole setup for you: it copies two vetted, Play-tested scripts VERBATIM (ThirdPersonController.cs — CharacterController movement + grounded jump, camera-relative input; FollowCamera.cs — modern mouse/right-stick orbit camera), ensures a Player capsule and a Main Camera exist, adds CharacterController to the Player, and attaches ThirdPersonController + FollowCamera automatically as soon as the scripts compile. After it returns, your ONLY remaining step is to call compile_scripts and wait for status='idle' — do NOT call add_component for the controller, the follow camera, or the character controller (the tool already handled all three), and no object-reference wiring is needed (the scripts self-resolve: ThirdPersonController → Camera.main, FollowCamera → the 'Player' tag). For a 2D SIDE-SCROLLING platformer player instead, use create_platformer_controller (a separate vetted template). Use create_script ONLY for other controllers with no template yet (top-down, twin-stick).",
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
            "name": "create_platformer_controller",
            "description": "ALWAYS use this — not create_script — for ANY request that wants a 2D SIDE-SCROLLING PLATFORMER player: a character that runs left/right AND jumps under 2D physics (a Mario-style platformer, a 2D jump-and-run). It is the 2D counterpart of create_third_person_controller. Hand-written 2D controllers reliably ship two runtime bugs: a mid-air jump (a collision-normal ground check done wrong) and a character that tips over (Rigidbody2D rotation left unfrozen). This tool is ATOMIC: it copies the vetted PlatformerController2D script VERBATIM (Rigidbody2D run + a grounded jump detected by a feet overlap test), builds a sprite Player with a Rigidbody2D (rotation frozen) + BoxCollider2D, adds an ORTHOGRAPHIC Main Camera, and (optionally) a ground platform, then attaches PlatformerController2D automatically as soon as the script compiles. After it returns your ONLY remaining step is compile_scripts (wait for status='idle') — do NOT call add_component or add the Rigidbody2D/collider yourself. Placeholder sprites are used; the player runs with A/D or arrows and jumps with Space. For the collectible/hazard loop around it, call create_game_manager, create_collectible and create_hazard with dimension='2d'. Use create_third_person_controller instead for a 3D player.",
            "parameters": {
                "type": "object",
                "properties": {
                    "directory": {
                        "type": "string",
                        "description": "Folder (relative to Assets) to write PlatformerController2D.cs into. Defaults to 'Scripts'. The filename is fixed (Unity requires the MonoBehaviour class name to match the file name).",
                    },
                    "playerName": {
                        "type": "string",
                        "description": "Name of the player GameObject. Defaults to 'Player'. If a GameObject with this name (or the 'Player' tag) already exists it is reused (and gets a Rigidbody2D + BoxCollider2D if missing); otherwise a sprite Player is created at (0,1,0) and tagged 'Player'. Errors if the reused object already carries 3D physics (Unity can't mix 2D and 3D physics on one object).",
                    },
                    "moveSpeed": {
                        "type": "number",
                        "description": "Horizontal run speed in units/second. Defaults to 7.",
                    },
                    "jumpForce": {
                        "type": "number",
                        "description": "Upward velocity applied on jump. Defaults to 12.",
                    },
                    "createGround": {
                        "type": "boolean",
                        "description": "Create a wide static ground platform when the scene has no floor-like object. Defaults to true so a standalone call yields a character that can stand. Set false if you are building the level yourself (e.g. with a tilemap).",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set true ONLY when the user explicitly asked to regenerate the controller. The shared PlatformerController2D.cs is REUSED (not clobbered) when present. Defaults to false.",
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
            "description": "Use this — not create_script — to add the HUB of a simple game: a GameManager that tracks SCORE and LIVES, RESPAWNS the player on a hit, handles WIN/LOSE, and builds its own on-screen HUD (score + lives readouts and a centered win/lose banner, R to restart). It is what turns a playable character into an actual game — something you can win or lose — and it is the counterpart create_collectible and create_hazard wire into. Call it once per scene. Hand-written game-state hubs reliably ship subtle bugs (scoring that keeps counting after the game ends, respawn that forgets to clear the player's velocity); this tool copies a vetted, Play-tested script VERBATIM instead. It is ATOMIC: it writes the script, creates the GameManager object, and attaches the GameManager component automatically as soon as the script compiles — so after it returns your ONLY remaining step is to call compile_scripts and wait for status='idle'. DO NOT call add_component for GameManager. Gameplay code reaches it WITHOUT a reference via the static GameManager.Instance (e.g. GameManager.Instance?.AddScore(1)); create_collectible and create_hazard already emit those calls. Works for 2D and 3D games — respawn handles CharacterController, Rigidbody, and Rigidbody2D, so it pairs with either create_third_person_controller or create_platformer_controller.",
            "parameters": {
                "type": "object",
                "properties": {
                    "directory": {
                        "type": "string",
                        "description": "Folder (relative to Assets) to write GameManager.cs into. Defaults to 'Scripts'. The filename is fixed (GameManager.cs) because Unity requires the MonoBehaviour class name to match the file name.",
                    },
                    "managerName": {
                        "type": "string",
                        "description": "Name of the GameManager GameObject. Defaults to 'GameManager'. If a manager already exists in the scene the tool refuses (two HUDs would fight) — reuse the existing one via GameManager.Instance.",
                    },
                    "startingLives": {
                        "type": "integer",
                        "description": "Lives the player starts with. Defaults to 3. 0 means a single life (game over on the first fatal hit).",
                    },
                    "scoreToWin": {
                        "type": "integer",
                        "description": "Score that triggers an automatic win. Defaults to 0, which means 'no score target': the game is instead won by collecting every collectible in the level (or by calling GameManager.Instance.Win() yourself from a goal). Set this to e.g. 10 for 'collect 10 coins to win'.",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set to true ONLY when the user explicitly asked to regenerate the GameManager script. The shared GameManager.cs is REUSED (not clobbered) when it already exists; this forces a fresh copy of the vetted template. Defaults to false.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_save_system",
            "description": "Use this — not create_script — to add a SAVE/LOAD system: the piece that makes a game REMEMBER between sessions (coins, unlocked levels, high scores, settings survive a quit). Trigger on 'save/load', 'persist', 'carry over between sessions', 'don't lose progress on quit', 'high score', 'save slots'. It writes a vetted SaveSystem MonoBehaviour that persists a typed key/value store as JSON to Application.persistentDataPath — the ONLY writable, per-user, cross-platform location. Hand-written save code reliably ships data-loss bugs, the #1 being PlayerPrefs (a size-limited registry/plist bucket, the wrong scope) or writing under the project folder (read-only in a built player); this tool avoids all of them and also tolerates a missing/corrupt file, supports multiple slots, and auto-saves on quit. It is ATOMIC: it writes the script, creates the SaveSystem object, and attaches the SaveSystem component automatically as soon as the script compiles (it also self-bootstraps on Play via RuntimeInitializeOnLoadMethod, so it works even in scenes without the object) — so after it returns your ONLY remaining step is compile_scripts (wait for status='idle'). DO NOT call add_component for SaveSystem. Reach it globally WITHOUT a reference via the static SaveSystem.Instance: SetInt(\"coins\", 42) to remember a value, GetInt(\"coins\", 0) to read it back with a default, Save() to flush to disk, HasSave() to gate a Continue button (SetFloat/GetFloat, SetString/GetString, SetBool/GetBool exist too). Works for 2D and 3D games. Call once per game.",
            "parameters": {
                "type": "object",
                "properties": {
                    "directory": {
                        "type": "string",
                        "description": "Folder (relative to Assets) to write SaveSystem.cs into. Defaults to 'Scripts'. The filename is fixed (SaveSystem.cs) because Unity requires the MonoBehaviour class name to match the file name.",
                    },
                    "saveSystemName": {
                        "type": "string",
                        "description": "Name of the SaveSystem GameObject. Defaults to 'SaveSystem'. If one already exists in the scene the tool reuses it (two savers would fight over the same file).",
                    },
                    "autosave": {
                        "type": "boolean",
                        "description": "Auto-save on quit (and on app-pause on mobile) so progress is never silently dropped. Defaults to true. Baked into the generated script, so it only applies when the script is (re)written.",
                    },
                    "defaultSlot": {
                        "type": "integer",
                        "description": "Which save slot the game starts on (0-based). Each slot is a separate file (savegame_<slot>.json). Defaults to 0. Baked into the generated script, so it only applies when the script is (re)written.",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set to true ONLY when the user explicitly asked to regenerate the SaveSystem script. The shared SaveSystem.cs is REUSED (not clobbered) when it already exists; this forces a fresh copy of the vetted template (and re-applies autosave/defaultSlot). Defaults to false.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_collectible",
            "description": "Use this — not create_script — to add a COLLECTIBLE (coin / star / pickup): a visible sphere with a trigger collider that, when the player (tag 'Player') touches it, adds to the score via the GameManager and removes itself. With create_game_manager and create_hazard it completes the core gameplay loop. ATOMIC: it writes a vetted trigger-pickup script, builds the pickup, and attaches the Collectible component automatically on the next compile — so after it returns your ONLY remaining step is compile_scripts. DO NOT call add_component. Call create_game_manager too, or the pickup vanishes without scoring (this tool ensures GameManager.cs exists so the pickup compiles, but does NOT add the HUD/win-logic hub — only create_game_manager does). Call repeatedly to place many pickups; the script is shared and each object gets a unique name. Works in 2D or 3D — pass dimension='2d' for a sprite pickup with a CircleCollider2D trigger (pair with create_platformer_controller), otherwise a 3D sphere is built.",
            "parameters": {
                "type": "object",
                "properties": {
                    "directory": {
                        "type": "string",
                        "description": "Folder (relative to Assets) for the generated scripts. Defaults to 'Scripts'. Filenames are fixed (Collectible.cs, and GameManager.cs as the compile contract).",
                    },
                    "name": {
                        "type": "string",
                        "description": "Name of the collectible GameObject. Defaults to 'Collectible'. If one with this name exists, a numeric suffix is added so each pickup is addressable.",
                    },
                    "dimension": {
                        "type": "string",
                        "enum": ["2d", "3d"],
                        "description": "'3d' (default) builds a sphere with a 3D trigger collider; '2d' builds a sprite with a CircleCollider2D trigger for a 2D game. Match the player: use '2d' alongside create_platformer_controller, '3d' alongside create_third_person_controller. The Collectible script itself is dimension-agnostic (handles both OnTriggerEnter and OnTriggerEnter2D).",
                    },
                    "value": {
                        "type": "integer",
                        "description": "Score added when this collectible is picked up. Defaults to 1.",
                    },
                    "x": {"type": "number", "description": "World X position. Defaults to 0."},
                    "y": {
                        "type": "number",
                        "description": "World Y position. Defaults to 1 (so it floats above the ground).",
                    },
                    "z": {"type": "number", "description": "World Z position. Defaults to 0 (ignored for 2D)."},
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set true ONLY to force-regenerate the shared Collectible.cs script. It is REUSED (not clobbered) when present. Defaults to false.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_hazard",
            "description": "Use this — not create_script — to add a HAZARD (spikes / lava / a pit trigger): a visible cube with a trigger collider that, when the player (tag 'Player') touches it, costs the player lives via the GameManager — which respawns the player while lives remain and ends the game at zero. With create_game_manager and create_collectible it completes the core gameplay loop (the way to LOSE). ATOMIC: it writes a vetted trigger-danger script, builds the danger volume, and attaches the Hazard component automatically on the next compile — so after it returns your ONLY remaining step is compile_scripts. DO NOT call add_component. Call create_game_manager too, or nothing happens on contact (this tool ensures GameManager.cs exists so the hazard compiles, but does NOT add the lives/respawn hub — only create_game_manager does). Call repeatedly to place many hazards. Works in 2D or 3D — pass dimension='2d' for a sprite with a BoxCollider2D trigger (pair with create_platformer_controller), otherwise a 3D cube is built.",
            "parameters": {
                "type": "object",
                "properties": {
                    "directory": {
                        "type": "string",
                        "description": "Folder (relative to Assets) for the generated scripts. Defaults to 'Scripts'. Filenames are fixed (Hazard.cs, and GameManager.cs as the compile contract).",
                    },
                    "name": {
                        "type": "string",
                        "description": "Name of the hazard GameObject. Defaults to 'Hazard'. A numeric suffix is added if the name is taken, so each hazard is addressable.",
                    },
                    "dimension": {
                        "type": "string",
                        "enum": ["2d", "3d"],
                        "description": "'3d' (default) builds a cube with a 3D trigger collider; '2d' builds a sprite with a BoxCollider2D trigger for a 2D game. Match the player: use '2d' alongside create_platformer_controller, '3d' alongside create_third_person_controller. The Hazard script itself is dimension-agnostic (handles both OnTriggerEnter and OnTriggerEnter2D).",
                    },
                    "damage": {
                        "type": "integer",
                        "description": "Lives removed when the player touches this hazard. Defaults to 1. The GameManager respawns the player while lives remain and ends the game at zero.",
                    },
                    "x": {"type": "number", "description": "World X position. Defaults to 0."},
                    "y": {"type": "number", "description": "World Y position. Defaults to 0.5."},
                    "z": {"type": "number", "description": "World Z position. Defaults to 0 (ignored for 2D)."},
                    "size": {
                        "type": "number",
                        "description": "Uniform scale of the hazard. Defaults to 1.",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set true ONLY to force-regenerate the shared Hazard.cs script. It is REUSED (not clobbered) when present. Defaults to false.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_health",
            "description": "Use this — not create_script — to add HEALTH (hit points) to an existing object: the foundation of the combat loop. Other systems damage it via Health.TakeDamage; at 0 HP it dies (and by default destroys the object). create_projectile damages Health; create_health_bar visualizes it; create_enemy already adds its own Health. ATOMIC: writes a vetted Health.cs and attaches the Health component on the next compile — your ONLY remaining step is compile_scripts. DO NOT call add_component. For a PLAYER pass destroyOnDeath=false (the GameManager owns player death via lives); for enemies/destructibles leave it true. Currently 3D-oriented but engine-agnostic.",
            "parameters": {
                "type": "object",
                "properties": {
                    "target": {
                        "type": "string",
                        "description": "Name (or tag) of the GameObject to add Health to. Defaults to 'Player'. Must already exist.",
                    },
                    "maxHealth": {
                        "type": "integer",
                        "description": "Maximum and starting hit points. Defaults to 3.",
                    },
                    "destroyOnDeath": {
                        "type": "boolean",
                        "description": "Destroy the object at 0 HP. Defaults to true (enemies/destructibles). Pass false for a player.",
                    },
                    "directory": {
                        "type": "string",
                        "description": "Folder (relative to Assets) for Health.cs. Defaults to 'Scripts'.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_health_bar",
            "description": "Use this — not create_script — to add a floating HEALTH BAR above an object that has Health: a camera-facing bar (green → red) that tracks the target's Current/Max each frame and disappears when the target dies. Visualizes the Health added by create_health / create_enemy. Built from SpriteRenderers (no Canvas, no custom material) so it renders in any pipeline. ATOMIC: writes a vetted HealthBar.cs, creates a child bar object, and attaches the HealthBar component on the next compile — your ONLY remaining step is compile_scripts. DO NOT call add_component. The target must have (or be queued to get) a Health component — add one with create_health or use create_enemy. Currently 3D.",
            "parameters": {
                "type": "object",
                "properties": {
                    "target": {
                        "type": "string",
                        "description": "Name (or tag) of the Health-bearing object to float the bar above. Defaults to 'Enemy'. Must already exist.",
                    },
                    "offsetY": {
                        "type": "number",
                        "description": "Height above the target's origin to float the bar. Defaults to 2.2.",
                    },
                    "width": {
                        "type": "number",
                        "description": "Bar width in world units. Defaults to 1.2.",
                    },
                    "height": {
                        "type": "number",
                        "description": "Bar height in world units. Defaults to 0.18.",
                    },
                    "hideWhenFull": {
                        "type": "boolean",
                        "description": "Hide the bar while the target is at full health. Defaults to false.",
                    },
                    "directory": {
                        "type": "string",
                        "description": "Folder (relative to Assets) for HealthBar.cs. Defaults to 'Scripts'.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_enemy",
            "description": "Use this — not create_script — to add an ENEMY: a visible capsule that chases the player across the ground and, on contact, costs the player a life via the GameManager. It carries Health, so create_projectile can destroy it. The antagonist of the combat loop. Hand-written chasers reliably ship bugs (chasing the player's vertical position so the enemy flies; draining every life in one contact frame); the vetted template chases on the ground plane and rate-limits its hits. ATOMIC: builds the capsule and attaches Enemy + Health on the next compile — your ONLY remaining step is compile_scripts. DO NOT call add_component. Call create_game_manager too (contact does nothing without it). Call repeatedly for many enemies (each gets a unique name). Currently 3D.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Name of the enemy GameObject. Defaults to 'Enemy'. A numeric suffix is added if taken so each enemy is addressable.",
                    },
                    "moveSpeed": {
                        "type": "number",
                        "description": "Chase speed in units/second. Defaults to 3.",
                    },
                    "health": {
                        "type": "integer",
                        "description": "Enemy hit points (how many projectile hits to kill it). Defaults to 3.",
                    },
                    "chase": {
                        "type": "boolean",
                        "description": "Whether the enemy chases the player. Defaults to true. False = stationary, damages only on contact.",
                    },
                    "x": {"type": "number", "description": "World X position. Defaults to 0."},
                    "y": {"type": "number", "description": "World Y position. Defaults to 1."},
                    "z": {
                        "type": "number",
                        "description": "World Z position. Defaults to 5 (in front of a player at the origin).",
                    },
                    "directory": {
                        "type": "string",
                        "description": "Folder (relative to Assets) for the generated scripts. Defaults to 'Scripts'.",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set true ONLY to force-regenerate the shared Enemy.cs. Reused (not clobbered) when present. Defaults to false.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_projectile",
            "description": "Use this — not create_script — to give the player the SHOOT verb: a PlayerShooter that on fire input (left mouse or F) spawns a projectile and launches it forward, aimed by the camera. Projectiles damage any Health they hit — so with create_enemy (enemies carry Health) this closes the combat loop (fight back). Hand-written shooters reliably re-derive broken code (projectiles that hit the firer, never despawn, or don't collide); the vetted templates handle ignore-the-shooter, a lifetime, and physics movement. No prefab — the projectile is built in code. ATOMIC: writes Projectile.cs + PlayerShooter.cs and attaches PlayerShooter to the player on the next compile — your ONLY remaining step is compile_scripts. DO NOT call add_component. Currently 3D.",
            "parameters": {
                "type": "object",
                "properties": {
                    "shooter": {
                        "type": "string",
                        "description": "Name (or tag) of the object to mount the shooter on. Defaults to 'Player'. Must already exist.",
                    },
                    "fireRate": {
                        "type": "number",
                        "description": "Shots per second. Defaults to 3.",
                    },
                    "projectileSpeed": {
                        "type": "number",
                        "description": "Projectile travel speed in units/second. Defaults to 14.",
                    },
                    "damage": {
                        "type": "integer",
                        "description": "Damage each projectile deals to a Health it hits. Defaults to 1.",
                    },
                    "directory": {
                        "type": "string",
                        "description": "Folder (relative to Assets) for the generated scripts. Defaults to 'Scripts'.",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set true ONLY to force-regenerate the shared Projectile.cs / PlayerShooter.cs. Reused (not clobbered) when present. Defaults to false.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_moving_platform",
            "description": "Use this — not create_script — to add a MOVING PLATFORM (elevator / patrolling ledge / gap-crosser): a flat kinematic box that travels a waypoint route at constant speed and CARRIES the player standing on it. The core verticality verb of a platformer. Hand-written moving platforms are reliably buggy (a CharacterController slides off; a transform-driven platform the physics step never sees; no platform-friction carry at all); the vetted MovingPlatform.cs drives a kinematic Rigidbody via MovePosition and carries the rider by parenting it while it stands on top. ATOMIC: it writes the vetted script, builds the box + kinematic Rigidbody, and attaches the MovingPlatform component automatically on the next compile — so after it returns your ONLY remaining step is compile_scripts. DO NOT call add_component. Waypoints are LOCAL offsets from where the platform is placed. Call repeatedly to place many platforms (the script is shared; each object gets a unique name). Currently 3D.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Name of the platform GameObject. Defaults to 'MovingPlatform'. A numeric suffix is added if the name is taken.",
                    },
                    "x": {"type": "number", "description": "World X of the platform's start position. Defaults to 0."},
                    "y": {"type": "number", "description": "World Y of the platform's start position. Defaults to 1."},
                    "z": {"type": "number", "description": "World Z of the platform's start position. Defaults to 0."},
                    "route": {
                        "type": "string",
                        "description": "Waypoints as LOCAL offsets from the start, formatted 'x,y,z;x,y,z;...'. The first point is the start; needs at least two points. Example: '0,0,0;0,4,0' for a vertical elevator. Defaults to '0,0,0;4,0,0' (a short horizontal sweep).",
                    },
                    "speed": {"type": "number", "description": "Travel speed in units per second. Defaults to 2."},
                    "loopMode": {
                        "type": "string",
                        "enum": ["loop", "pingpong", "once"],
                        "description": "How the platform repeats its route: 'loop' (run start→end→start…), 'pingpong' (bounce end to end), 'once' (travel then stop). Defaults to 'loop'.",
                    },
                    "waitTime": {
                        "type": "number",
                        "description": "Seconds to pause at each endpoint (pingpong/once). Defaults to 0.",
                    },
                    "width": {"type": "number", "description": "Platform width (X) in world units. Defaults to 3."},
                    "depth": {"type": "number", "description": "Platform depth (Z) in world units. Defaults to 3."},
                    "thickness": {
                        "type": "number",
                        "description": "Platform thickness (Y) in world units. Defaults to 0.4.",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set true ONLY to force-regenerate the shared MovingPlatform.cs script. It is REUSED (not clobbered) when present. Defaults to false.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_screen_shake",
            "description": "Use this — not create_script — to add trauma-based SCREEN SHAKE to the camera: writes a vetted CameraShake script and attaches it to the main camera (found, or created if the scene has none). The other half of 'juice' alongside hit VFX — a camera kick on impact/landing/death makes a hit feel like it connected. Hand-written shake is reliably bad (per-frame random jitter that reads as static; intensity-linear shake that can't be both subtle and violent; shake that never decays; shake that fights a following camera). The vetted CameraShake.cs is trauma-based (shake = trauma squared), smooth-noise driven, self-decaying, and RECOVERS the follow pose each frame so it composes with FollowCamera instead of fighting it. Trigger it from gameplay code with 'CameraShake.Shake(0.5f);' (0..1). ATOMIC: writes the script and attaches the CameraShake component on the next compile — your ONLY remaining step is compile_scripts. DO NOT call add_component. Call once per scene. Currently 3D.",
            "parameters": {
                "type": "object",
                "properties": {
                    "cameraName": {
                        "type": "string",
                        "description": "Name of the camera object to shake. Defaults to the main camera (Camera.main, then any camera, else a new one is created). Pass a name only to target a specific non-main camera.",
                    },
                    "directory": {
                        "type": "string",
                        "description": "Folder (relative to Assets) for CameraShake.cs. Defaults to 'Scripts'.",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set true ONLY to force-regenerate the shared CameraShake.cs script. It is REUSED (not clobbered) when present. Defaults to false.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_level_system",
            "description": "Use this — not create_script — to add the PROGRESSION hub: a LevelSystem that tracks XP and LEVEL, levels the player up when XP fills, grows the player's max health (and heals to full) on each level up, and builds its own on-screen HUD (a level readout + XP bar). The counterpart to create_game_manager's score/lives — the part that makes the game worth continuing to play. Hand-written XP/level systems reliably ship bugs (XP that doesn't roll over on a big reward, a bar that divides by zero at the cap, growth that fights whichever object inits first); the vetted LevelSystem.cs avoids those and exposes a static LevelSystem.Instance so gameplay code reaches it without a reference (LevelSystem.Instance?.AddXP(5)). ATOMIC: writes the vetted script (and ensures Health.cs, the stat it grows), creates the LevelSystem object, and attaches the LevelSystem component automatically on the next compile — your ONLY remaining step is compile_scripts. DO NOT call add_component. Call once per scene; pair with create_loot_drop so enemies feed it XP. Currently 3D.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Name of the LevelSystem GameObject. Defaults to 'LevelSystem'. A second LevelSystem is refused (reuse the existing one via LevelSystem.Instance).",
                    },
                    "baseXP": {
                        "type": "integer",
                        "description": "XP required to go from level 1 to level 2. Defaults to 5.",
                    },
                    "xpGrowth": {
                        "type": "integer",
                        "description": "Extra XP each subsequent level needs over the previous one (a gentle ramp). Defaults to 3.",
                    },
                    "healthPerLevel": {
                        "type": "integer",
                        "description": "Max health added to the player on each level up (then healed to full). Defaults to 1. Set 0 to disable health growth (e.g. if you grow other stats via the OnLevelUp broadcast).",
                    },
                    "directory": {
                        "type": "string",
                        "description": "Folder (relative to Assets) for the generated scripts. Defaults to 'Scripts'.",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set true ONLY to force-regenerate the shared LevelSystem.cs script. It is REUSED (not clobbered) when present. Defaults to false.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_loot_drop",
            "description": "Use this — not create_script — to make an object GRANT XP WHEN IT DIES: turns an enemy (or any Health-bearing destructible) into a source of progression, so killing it levels the player up. Closes the progression loop alongside create_level_system. The reliable way to reward a kill is to hook the object's Health.onDeath (fires once, right before destroy) — not to poll or bake the reward into the killer; the vetted LootDrop.cs does exactly that and no-ops cleanly when no LevelSystem is present. ATOMIC: writes the vetted script (and ensures Health.cs + the LevelSystem.cs contract it feeds) and attaches the LootDrop component to the target on the next compile — your ONLY remaining step is compile_scripts. DO NOT call add_component. Call create_level_system too, or the XP has nowhere to land. Call repeatedly to reward many enemies. Currently 3D.",
            "parameters": {
                "type": "object",
                "properties": {
                    "target": {
                        "type": "string",
                        "description": "Name (or tag) of the object that should grant XP on death. Defaults to 'Enemy'. Must already exist; RequireComponent adds a Health if it has none, but use create_enemy / create_health for real hit points.",
                    },
                    "xp": {
                        "type": "integer",
                        "description": "XP granted to the player's LevelSystem when the target dies. Defaults to 3.",
                    },
                    "directory": {
                        "type": "string",
                        "description": "Folder (relative to Assets) for the generated scripts. Defaults to 'Scripts'.",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set true ONLY to force-regenerate the shared LootDrop.cs script. It is REUSED (not clobbered) when present. Defaults to false.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_pause_menu",
            "description": "Use this — not create_script — to add a PAUSE MENU: a vetted PauseMenu that freezes the game (Time.timeScale = 0) on a key press (Escape by default) and shows a dimmed overlay with Resume / Restart / Quit, then un-freezes on resume. It builds its own Canvas, buttons, and EventSystem at runtime, so the scene needs no UI setup. Hand-written pause menus reliably ship bugs — the unpause key read on a timeScale-bound clock (so the menu can't be closed), a missing EventSystem / input module (so the buttons are dead on click), or a Restart that reloads the scene without restoring timeScale (so it loads frozen). The vetted PauseMenu.cs polls the key through the new Input System (immune to timeScale), ensures an EventSystem, restores the interrupted timeScale on resume, and always resets timeScale before a reload. Lock pausing from gameplay code via PauseMenu.Instance?.SetPausable(false). ATOMIC: writes the vetted script, creates the PauseMenu object, and attaches the PauseMenu component automatically on the next compile — your ONLY remaining step is compile_scripts. DO NOT call add_component, create_canvas, or create_event_system. Call once per scene.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Name of the PauseMenu GameObject. Defaults to 'PauseMenu'. A second pause menu is refused (reuse the existing one via PauseMenu.Instance).",
                    },
                    "pauseKey": {
                        "type": "string",
                        "description": "Key that toggles pause. Any UnityEngine.InputSystem.Key name — 'Escape' (default), 'P', 'Tab', 'Backspace', etc. An unrecognized name falls back to Escape.",
                    },
                    "directory": {
                        "type": "string",
                        "description": "Folder (relative to Assets) for PauseMenu.cs. Defaults to 'Scripts'.",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set true ONLY to force-regenerate the shared PauseMenu.cs script. It is REUSED (not clobbered) when present. Defaults to false.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_main_menu",
            "description": "Use this — not create_script — to add a START / TITLE SCREEN: a vetted StartMenu that freezes the game (Time.timeScale = 0) on play and shows a full-screen title card with Play and Quit buttons, then un-freezes and removes itself when the player presses Play. It builds its own Canvas, buttons, and EventSystem at runtime, so the scene needs no UI setup — and no second scene or Build Settings change. This is an IN-SCENE overlay: it gives the 'title → game' flow immediately in the current scene (a separate menu scene would need both scenes saved AND registered in Build Settings, which is brittle to scaffold). Hand-written title screens reliably ship bugs — a missing EventSystem / input module (Play unclickable), a menu that doesn't actually freeze the game (it plays out behind the card), or a dismiss that forgets to restore timeScale (game stays frozen). The vetted StartMenu.cs handles all three. ATOMIC: writes the vetted script, creates the StartMenu object, and attaches the StartMenu component automatically on the next compile — your ONLY remaining step is compile_scripts. DO NOT call add_component, create_canvas, or create_event_system. Call once per scene.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Name of the StartMenu GameObject. Defaults to 'StartMenu'. A second start menu is refused (reuse the existing one via StartMenu.Instance).",
                    },
                    "title": {
                        "type": "string",
                        "description": "Big title shown on the start screen. Defaults to 'My Game'. Use the game's name when the user has given one.",
                    },
                    "subtitle": {
                        "type": "string",
                        "description": "Smaller line under the title (e.g. a controls hint like 'WASD to move, Space to jump'). Defaults to 'Press Play to start'. Empty string hides it.",
                    },
                    "freezeUntilStart": {
                        "type": "boolean",
                        "description": "Freeze the game (Time.timeScale = 0) until the player presses Play. Defaults to true. Set false for a title card that overlays a scene already in motion (e.g. an attract/demo loop behind the menu).",
                    },
                    "directory": {
                        "type": "string",
                        "description": "Folder (relative to Assets) for StartMenu.cs. Defaults to 'Scripts'.",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set true ONLY to force-regenerate the shared StartMenu.cs script. It is REUSED (not clobbered) when present. Defaults to false.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_sound_effects",
            "description": "Use this — not create_script / create_audio_source — to add SOUND EFFECTS: a vetted SoundEffects jukebox that SYNTHESIZES short retro blips at runtime (no imported .wav files needed) and plays them on demand, so a freshly-scaffolded game stops being silent. It auto-wires combat audio — it watches every Health and plays a 'hit' on damage and a 'death' on death — and exposes a static SoundEffects.Play(cue) for the rest. Hand-rolled SFX stalls on the asset problem (no clips to import, so the AI skips sound or references clips that don't exist); procedural generation always works in any project, and the synthesis (phase-accurate sweeps, per-sample envelopes, clean note boundaries) is easy to get subtly wrong by hand (clicks, clipping). Cues: 'jump', 'shoot', 'collect', 'levelup', 'hit', 'death', 'hurt'. Combat cues fire automatically; wire the others with one line where the event happens — e.g. SoundEffects.Play(\"jump\") in the jump code, Play(\"shoot\") on fire, Play(\"collect\") on pickup, Play(\"levelup\") on level up. ATOMIC: writes the vetted script (and ensures Health.cs, the type its combat hook reads), creates the SoundEffects object, and attaches the SoundEffects component automatically on the next compile — your ONLY remaining step is compile_scripts. DO NOT call add_component, create_audio_source, or assign_audio_clip. Call once per scene.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Name of the SoundEffects GameObject. Defaults to 'SoundEffects'. A second one is refused (reuse via the static SoundEffects.Play).",
                    },
                    "volume": {
                        "type": "number",
                        "description": "Master volume for every cue, 0..1. Defaults to 0.5.",
                    },
                    "autoHookCombat": {
                        "type": "boolean",
                        "description": "Automatically play 'hit' when any Health takes damage and 'death' when one dies. Defaults to true. Set false to drive every cue manually via SoundEffects.Play(cue).",
                    },
                    "directory": {
                        "type": "string",
                        "description": "Folder (relative to Assets) for the generated scripts. Defaults to 'Scripts'.",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set true ONLY to force-regenerate the shared SoundEffects.cs script. It is REUSED (not clobbered) when present. Defaults to false.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_hit_vfx",
            "description": "Use this — not create_script — to add HIT VFX: a vetted HitVFX system that pops a particle burst where a hit lands and where something dies — the spark that makes a hit read as CONNECTING (the visual half of 'juice' alongside create_screen_shake). It builds its own ParticleSystem at runtime (no art, no prefab) and auto-wires combat — it watches every Health and bursts on damage (small) and on death (big) — and composes with create_screen_shake (nudges CameraShake on each burst if one is present, via reflection, so there's no hard dependency). A runtime particle burst with no imported material reliably renders pink/invisible (the default ParticleSystem material isn't pipeline-safe); the vetted HitVFX builds a Sprites/Default material with a generated soft-dot texture that renders in both URP and the built-in pipeline, and reuses one pooled system instead of leaking a GameObject per hit. Trigger a manual burst with the static HitVFX.Burst(transform.position) (or HitVFX.Burst(point, 2f) for a bigger pop). ATOMIC: writes the vetted script (and ensures Health.cs, the type its combat hook reads), creates the HitVFX object, and attaches the HitVFX component automatically on the next compile — your ONLY remaining step is compile_scripts. DO NOT call add_component. Call once per scene.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Name of the HitVFX GameObject. Defaults to 'HitVFX'. A second one is refused (reuse via the static HitVFX.Burst).",
                    },
                    "colorHex": {
                        "type": "string",
                        "description": "Hex color of the spark, e.g. '#FFD27F' (warm) or '#66CCFF' (cool). Defaults to '#FFD27F'. An unparseable value falls back to warm white.",
                    },
                    "autoHookCombat": {
                        "type": "boolean",
                        "description": "Automatically burst when any Health takes damage (small) or dies (big). Defaults to true. Set false to drive bursts manually via HitVFX.Burst(position).",
                    },
                    "directory": {
                        "type": "string",
                        "description": "Folder (relative to Assets) for the generated scripts. Defaults to 'Scripts'.",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set true ONLY to force-regenerate the shared HitVFX.cs script. It is REUSED (not clobbered) when present. Defaults to false.",
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
            "description": "Modify an existing text-based asset file (.cs, .shader, .compute, etc.). File MUST exist — verify in Unity context first. TWO MODES: (1) SURGICAL EDIT (preferred for anything but a near-total rewrite) — pass oldString + newString to replace one exact snippet, leaving the rest of the file untouched. Far cheaper and safer on large files than resending the whole thing. (2) FULL REWRITE — pass scriptContent with the complete file. SAFETY: the bridge refuses modify_script against scripts the agentic loop did NOT create in this session unless confirmExistingFileModification=true is set. Set the flag ONLY when the user explicitly named the file (e.g. 'update PlayerMovement.cs') or used language like 'extend' / 'modify the existing X'. Absent that signal, do NOT set the flag and do NOT call modify_script — call create_script with a new path for fresh-scaffold prompts.",
            "parameters": {
                "type": "object",
                "properties": {
                    "scriptPath": {
                        "type": "string",
                        "description": "Path relative to Assets folder with file extension (e.g., 'Scripts/MyScript.cs', 'Shaders/MyShader.shader'). MUST match exactly a path shown in the Unity context. If the file is not listed in context, it doesn't exist - use create_script instead. Follow the project's existing folder structure.",
                    },
                    "oldString": {
                        "type": "string",
                        "description": "SURGICAL EDIT MODE: the exact snippet to replace, copied verbatim from the current file (whitespace and indentation included). Must be UNIQUE in the file — include enough surrounding lines to disambiguate, or set replaceAll=true. Read the file first (get_script_content, optionally with startLine/endLine) to copy the snippet exactly. When set, scriptContent is ignored.",
                    },
                    "newString": {
                        "type": "string",
                        "description": "SURGICAL EDIT MODE: the replacement for oldString. Use an empty string to delete the snippet. Required whenever oldString is set.",
                    },
                    "replaceAll": {
                        "type": "boolean",
                        "description": "SURGICAL EDIT MODE: replace every occurrence of oldString instead of requiring it to be unique. Default false (a non-unique oldString is rejected so you never edit the wrong spot). Useful for renaming a repeated local identifier.",
                    },
                    "scriptContent": {
                        "type": "string",
                        "description": "FULL REWRITE MODE: complete modified file content. MUST include ALL existing code from the context, then ADD your changes. Never remove existing fields, methods, or functionality. Prefer oldString/newString for small changes to large files. For .cs files: complete C# script code. For .shader files: complete HLSL/CG shader code.",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set to true ONLY when the user explicitly named the file to extend or modify (e.g. 'update PlayerMovement.cs', 'extend the existing HealthSystem'). Required for any modify_script against a script not created via create_script in the current session. Defaults to false. Setting this without explicit user authorization risks corrupting real project code.",
                    },
                },
                "required": ["scriptPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_script_content",
            "description": "Read a text-based asset file by path (e.g., 'Assets/Scripts/PlayerMovement.cs', 'Assets/Shaders/MyShader.shader'). Supports .cs (C# scripts), .shader (HLSL/CG shaders), .compute (compute shaders), .hlsl, .cginc, and other text-based Unity assets. Reads the WHOLE file by default. For a LARGE file, pass startLine/endLine to read just the range you need instead of loading thousands of lines into context — the response always includes totalLines so you know how much you didn't read. Use this when the user asks to fix or update a specific script or shader.",
            "parameters": {
                "type": "object",
                "properties": {
                    "scriptPath": {
                        "type": "string",
                        "description": "Path to the file with extension (relative to Assets, e.g., 'Scripts/MyScript.cs' or 'Shaders/MyShader.shader').",
                    },
                    "startLine": {
                        "type": "integer",
                        "description": "Optional 1-based first line to read (inclusive). Omit (or 0) to start at the top. Pair with endLine to read one method/region out of a big file.",
                    },
                    "endLine": {
                        "type": "integer",
                        "description": "Optional 1-based last line to read (inclusive). Omit (or 0) to read to the end of the file.",
                    },
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
            "name": "find_references",
            "description": "Find every script that references a symbol (a class, method, or field name), with per-file line context. Matches whole identifiers only (so 'Player' does NOT match 'PlayerController'), unlike the raw substring search_scripts. ALWAYS call this BEFORE renaming, changing the signature of, or refactoring a public class/method/field — it reveals the dependent scripts a change would break so you can update them too. Returns files ordered by reference count (heaviest dependents first). totalFileCount / totalMatches report the TRUE project-wide blast radius even when line detail is capped at maxFiles, and truncated=true means more files reference the symbol than were returned — raise maxFiles (or update the returned files first, then re-run) so you don't refactor against a partial picture.",
            "parameters": {
                "type": "object",
                "properties": {
                    "symbol": {
                        "type": "string",
                        "description": "The identifier to find references to — a class, method, or field name (e.g. 'PlayerController', 'TakeDamage', 'maxHealth').",
                    },
                    "maxFiles": {
                        "type": "integer",
                        "description": "Max distinct files to return WITH line detail (1-100). Default: 40. The scan still counts every referencing file for totalFileCount regardless of this cap.",
                    },
                    "maxMatchesPerFile": {
                        "type": "integer",
                        "description": "Max line snippets returned per file (1-50). Default: 5. The per-file count is always exact even when snippets are capped.",
                    },
                },
                "required": ["symbol"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "find_component_usages",
            "description": "Find every prefab asset and open-scene GameObject that has a component of a given type — the Inspector-WIRING counterpart to find_references (which covers code). Use it to see the blast radius BEFORE removing/renaming a MonoBehaviour or changing a component: the scenes/prefabs where it's attached are invisible in the source because that wiring lives in scene/prefab data, not scripts. Accepts a script class name ('PlayerController') or a built-in component ('Rigidbody', 'BoxCollider'). Returns each usage as {location: 'scene'|'prefab', container, gameObject, componentType}.",
            "parameters": {
                "type": "object",
                "properties": {
                    "componentType": {
                        "type": "string",
                        "description": "The component or MonoBehaviour script type name to locate (simple name, e.g. 'PlayerController', 'Rigidbody'). Case-insensitive.",
                    },
                    "maxResults": {
                        "type": "integer",
                        "description": "Max usages to return (1-200). Default: 60",
                    },
                },
                "required": ["componentType"],
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
    {
        "type": "function",
        "function": {
            "name": "create_parallax_layer",
            "description": "Use this — not create_script — to add one PARALLAX LAYER (distant mountains, drifting clouds, foreground bushes): a sprite under a shared 'ParallaxBackground' root that shifts with the camera to fake depth in 2D games. scrollFactor is the layer's distance: 1 = foreground (moves with the world), 0 = infinitely far (moves with the camera); call once per depth band, e.g. sky 0.1, mountains 0.3, trees 0.6, with sortingOrder rising toward the front. repeatX tiles the sprite sideways forever without a seam. ATOMIC: it writes the vetted ParallaxLayer2D script, builds the sprite layer (a tinted placeholder square when no spritePath is given), and attaches the component automatically on the next compile — so after it returns your ONLY remaining step is compile_scripts. DO NOT call add_component.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Layer GameObject name. Defaults to 'ParallaxLayer'. A numeric suffix is added if the name is taken.",
                    },
                    "spritePath": {
                        "type": "string",
                        "description": "Sprite asset for the layer. Omit for a tinted placeholder square you can replace later.",
                    },
                    "spriteName": {
                        "type": "string",
                        "description": "Sprite name inside a sliced spritesheet at spritePath",
                    },
                    "color": {
                        "type": "string",
                        "description": "Tint as 'r,g,b' or 'r,g,b,a' (0-1 floats). Useful to shade placeholder or distance-fade layers.",
                    },
                    "scrollFactor": {
                        "type": "number",
                        "description": "Depth: 1 = foreground (moves with world), 0 = infinitely far (moves with camera). Defaults to 0.5.",
                    },
                    "autoScrollSpeed": {
                        "type": "number",
                        "description": "Constant horizontal drift in units/second (clouds). Defaults to 0.",
                    },
                    "repeatX": {
                        "type": "boolean",
                        "description": "Tile the sprite horizontally forever (self-clones and wraps). Defaults to true.",
                    },
                    "sortingOrder": {
                        "type": "integer",
                        "description": "Render order — lower is further back. Defaults to -10.",
                    },
                    "position": {"type": "string", "description": "Layer position as 'x,y'. Defaults to '0,0'."},
                    "scale": {"type": "number", "description": "Uniform sprite scale. Defaults to 1."},
                    "directory": {
                        "type": "string",
                        "description": "Folder for the shared ParallaxLayer2D.cs script. Defaults to 'Assets/Scripts'.",
                    },
                    "confirmExistingFileModification": {
                        "type": "boolean",
                        "description": "Set true ONLY to force-regenerate the shared ParallaxLayer2D.cs script. It is REUSED (not clobbered) when present. Defaults to false.",
                    },
                },
                "required": [],
            },
        },
    },
]
