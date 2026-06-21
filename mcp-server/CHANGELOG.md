# Changelog

All notable changes to `gladekit-mcp` are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.9] - 2026-06-21

### Added

- **Godot bridge addon v0.7.0 — first-class 2D support and a complete prototype-game toolkit (29 new tools, 60 → 88).** The bridge was previously 3D-biased; this release makes 2D a first-class citizen and adds vetted, one-call scaffolders for the pieces a playable prototype needs — controllers, enemies, a win/lose loop, menus, navigation, and juice. New tool schemas are exposed to MCP clients accordingly.
  - **Dimension awareness.** `get_project_info` reports the project's `workspace` and `get_scene_tree` reports the scene's `root_space` (`2d` / `3d`), so a client can tell which kind of scene it's editing. The dimension-aware creators (`create_camera`, `create_light`, `create_material`, `create_physics_body`) **infer** the space from the open scene's root when it isn't passed, so a bare `create_camera` in a 2D scene yields a `Camera2D`. Single-dimension tools attach a self-correcting hint when used in the other kind of scene. `create_camera` supersedes the old `create_camera_3d` name, which remains callable as an alias.
  - **2D scene building.** `create_sprite_2d`, `create_animated_sprite_2d` (with optional spritesheet slicing), `create_tilemap_layer` (TileMapLayer + TileSet atlas), `set_tilemap_cells` (paint / fill / erase), `set_tilemap_collision` (make tiles solid), and `create_parallax_2d` (scrolling backgrounds).
  - **Asset pipeline.** `import_asset` downloads and installs an external asset and `list_imported_assets` reports what's been brought in, with a license/attribution audit. Imports apply pixel-art-friendly texture filtering and seamless music looping where appropriate.
  - **Audio.** `create_audio_player` places a player and `set_audio_player_properties` configures it; stream assignment reuses the existing resource setter. Non-positional by default (music / UI), positional on request (`AudioStreamPlayer2D` / `3D`).
  - **AnimationTree state machine.** `create_animation_tree`, `add_state_machine_state`, `add_state_machine_transition`, and `get_animation_tree_info` — a state-machine animation layer over an existing `AnimationPlayer`.
  - **Vetted character controllers.** `create_third_person_controller` (3D) and `create_2d_controller` (`platformer` / `top_down`) write known-good movement scripts verbatim and assemble the player, camera, input actions, and (for platformers) ground — carrying the game-feel details a from-scratch script tends to drop (coyote time, jump buffering, variable jump height; normalized diagonals for top-down).
  - **Game feel / juice.** `create_particles_2d` and `create_particles_3d` add a tuned `GPUParticles2D` / `GPUParticles3D` from a preset (`explosion` / `sparkle` / `smoke` / `fire` / `trail`) — visible immediately, no texture needed. `create_screen_shake` attaches a trauma-based, noise-driven shake to the camera that composes with a follow camera.
  - **Gameplay loop.** `create_game_manager` builds a manager + HUD (score, lives, win/lose banner) and handles respawn and end-of-game; `create_collectible` and `create_hazard` add trigger areas that drive score and lives. The three compose into a winnable/losable game.
  - **Enemies.** `create_enemy_2d` (moving, stompable) and `create_enemy_3d` (line-of-sight guard behavior, with optional navmesh pursuit).
  - **3D navigation.** `add_navigation_agent` and `bake_navigation_mesh` set up pathfinding, including navmesh-driven enemy pursuit.
  - **Menus / scene flow.** `create_main_menu` (title screen) and `create_pause_menu` (in-game overlay) with working scene transitions.

## [0.7.8] - 2026-06-11

### Added

- **Godot bridge addon v0.6.6 — editor main-thread stall watchdog.** Tool execution waits on the Godot editor's main thread; when that thread wedges (an open modal dialog, a long synchronous import/scan), every queued and subsequent `tools/execute` call previously rode out the client's full 30s timeout with an opaque "timed out" error, making the bridge look dead even though it was reachable. Two-layer fix:
  - **Bridge:** the worker thread now expires `tools/execute` dispatches that sit undispatched for 25s and answers them with a structured error naming the stall ("editor's main thread has not processed bridge work for Xs") plus `possible_solutions[]` (dismiss the dialog / wait out the import / restart the editor). The `health` endpoint reports `mainThreadStalledMsec` — how long since the main thread last made progress — which stays readable during a stall because health answers from the worker thread. Dispatches are drained one at a time (previously bulk) so queued work stays visible to the watchdog while an earlier tool executes, and a long multi-tool batch refreshes the heartbeat between tools so "busy" isn't misreported as "wedged".
  - **MCP server:** a `tools/execute` timeout now triggers a follow-up health probe and appends a diagnosis to the error — editor wedged (with stall duration and the modal-dialog hint), editor healthy but tool slow (suggest retry/smaller steps), or bridge gone (editor crashed/closed). Works against older bridges too, with a less precise "busy or blocked" message when `mainThreadStalledMsec` is absent. New `GodotBridgeTimeoutError` (subclass of `GodotBridgeError`) distinguishes deadline expiry from transport failure.

### Fixed

- **Godot 4.6 compatibility in the bridge's editor-singleton probes.** On 4.6, `Engine.has_singleton("EditorInterface")` returns `true` even outside the editor (game-runtime / headless test context), but `Engine.get_singleton()` then raises a C++ "Can't retrieve singleton outside of editor" error. All EditorInterface lookups now route through a new `ToolUtils.get_editor_interface_safe()` gated on `Engine.is_editor_hint()`, so headless/GUT runs stay error-free. Also on 4.6, passing an already-freed node to a `Node`-typed parameter raises at the call boundary before any validity check can run — `ToolUtils.deselect_before_free` now takes an untyped parameter and validates inside, preserving its tolerate-freed-nodes contract.

## [0.7.6] - 2026-06-08

### Added

- **Godot bridge addon v0.6.4 — context-engineering polish on two heavily-used reads (`get_script_content` pagination + `get_scene_tree` `response_format`).** Two tools with the highest per-call token footprint now expose knobs that let the agent pull only what it actually needs.
  - `get_script_content` is now paginated by line. New args `start_line` (1-indexed, default 1), `end_line` (1-indexed inclusive, default 0 = until EOF), and `max_lines` (default 500, clamped 1..5000) replace the previous "always return the whole file" behavior. The response always carries `total_lines` and `truncated` so the agent knows whether to request the next slice. Past-EOF reads return `success` with an empty `content` plus a diagnostic message so a wrong `start_line` self-corrects on the next call instead of looping. Non-agent callers that want the whole file in one shot can pass `max_lines=5000` (the hard cap).
  - `get_scene_tree` gains a `response_format` arg: `"both"` (default, returns the nested JSON `tree` AND the ASCII `tree_text`), `"tree_text_only"` (drops the JSON tree — ~half the response size on large scenes, and the ASCII view is already the model-friendly one), or `"tree_only"` (drops the ASCII for programmatic callers). Scene metadata (`scene_path`, `node_count`) is in every mode. Unknown formats return a structured error with `possible_solutions` listing the valid values. The aggregating `context/gather` endpoint pins `response_format="both"` so it keeps returning both shapes regardless of future default changes.
- **Godot bridge addon v0.6.3 — 2D physics bodies in `create_physics_body`.** `create_physics_body` previously built only 3D bodies, so 2D games (platformers, top-down) had no one-call body + collision setup. A new `space` arg (`"3d"` default / `"2d"`) switches the node family: `space="2d"` creates a `StaticBody2D` / `RigidBody2D` / `CharacterBody2D` with a matching `CollisionShape2D` child — `box`→`RectangleShape2D`, `circle`→`CircleShape2D`, `capsule`→`CapsuleShape2D` — sized in pixels (default 32×32) at a 2D position. The 3D path is unchanged (regression-tested). Adds `ToolUtils.parse_vector2_arg` so 2-component `"x,y"` values (2D positions and shape sizes) parse correctly instead of silently falling back to defaults.
- **Godot bridge addon v0.6.2 — `set_node_property` (generic node configuration).** `create_node` can spawn any node class, but configuring the result previously required a specialized setter per concern (transform, resource, light, material). `set_node_property` sets any non-Resource property on any node via reflection — scalars, vectors, colors, booleans, and enums — so `AudioStreamPlayer.volume_db`, `Camera3D.fov`, `GPUParticles3D.amount`, `RigidBody3D.mass`, and the like are all reachable through one tool. Values coerce to the property's declared type (numeric strings → numbers, `"x,y,z"` / `[x,y,z]` → vectors, `"#rrggbb"` → colors, enum labels like `"PROCESS_MODE_ALWAYS"` → their int); Resource-typed properties are rejected with a redirect to `set_node_resource`; unknown names return the node's settable properties plus the nearest match. `get_node_info` gains an `include_properties` flag that returns the current values of exactly those settable properties, so a client can read before it writes.
- **Godot bridge addon v0.6.1 — `add_input_action` (InputMap action setup).** A fresh Godot project ships with only the engine `ui_*` defaults, so a movement/jump/interact script that calls `Input.is_action_pressed("move_forward")` or `Input.get_vector(...)` against custom action names errors on every frame — and there was previously no tool to define those actions. `add_input_action` registers (or replaces) a custom action and binds keyboard keys to it: the action is saved to `project.godot` (survives restarts, appears under Project Settings > Input Map) and mirrored into the live `InputMap` so it fires the moment the project runs. Keys bind as physical keys (WASD survives non-QWERTY layouts), key names accept editor-style strings (`"W"`, `"Space"`, `"Escape"`, arrow keys), unrecognized names return `possible_solutions[]`, and re-running with `overwrite=true` (the default) is idempotent. Refused during play mode.

### Fixed

- **Scene-root node-path resolution.** Path-targeting tools (`create_primitive_3d`, `set_node_transform`, `set_node_parent`, and others that resolve a `parent_path` / node path) failed with `Parent node '<Name>' not found` when an agent named the scene root itself — e.g. `parent_path: "Main"` when the edited scene root is `Main`. The resolver's descendant search never matched the root node, so the most natural way to reference the root broke. It now resolves a bare root name, and strips a leading root-name segment from a slash path (`"Main/Player"` → `Player` under root), removing a class of avoidable failures.

- **Godot bridge addon v0.6.0 — AnimationPlayer + Animation .tres scaffolding (5 tools).** Closes the gap between an empty AnimationPlayer + an empty Animation resource and a playable, scene-saved animation library:
  - `add_animation_to_player` — register an Animation .tres with a player under a library + name (default library `""`, the conventional setup). Creates the library on first registration; refuses to overwrite an existing entry.
  - `add_animation_track` — add a track to an Animation. Five track types: `value` (any property — path `Node:property`), `position_3d` / `rotation_3d` / `scale_3d` (Node3D transform — more efficient than value-track equivalents), `method` (calls a function at keyframes).
  - `add_animation_keyframe` — insert a keyframe at time T with value V. Value parsing dispatches on the track's type read from the resource: Vector3 for position/scale, Quaternion (auto-converted from Euler degrees to match `set_node_transform`'s convention) for rotation, pass-through for value/method.
  - `set_animation_properties` — length, loop_mode (`"none" | "linear" | "ping_pong"` or 0/1/2), step. Refuses empty calls noisily (set_node_transform's 0.5.8 pattern).
  - `get_animation_player_info` — read-only inspection: libraries + animations + playback state + top-level properties (root_node, autoplay, default blend time). Safe in play mode.
  - The AnimationPlayer node and Animation .tres themselves are created via existing `create_node(type='AnimationPlayer')` + `create_resource(type='Animation')`, so the five tools above close the workflow without duplicating those creators. Typical scaffold for a 0.6s jump: `create_node` → `create_resource` → `add_animation_to_player` → `add_animation_track(position_3d)` → 3× `add_animation_keyframe` (t=0/0.3/0.6) → `set_animation_properties(length=0.6, loop_mode='none')`.
- **Godot bridge addon v0.5.9** — unknown-tool typo recovery. When `tools/execute` receives a tool name that isn't registered, the dispatcher now returns up to 3 levenshtein-ranked neighbors as `possible_solutions[]`, capped at edit distance 4 from the input. Previously the error was a naked `"Unknown tool '<name>'"` with no recovery surface, so a single-character typo (`get_node_inf` instead of `get_node_info`) cost the agent a round-trip through `tools/list` to find the right name. Threshold tuned to catch single-character drops/swaps in the 12–20-char tool-name range without surfacing spurious hits on wild-miss queries. Reuses the `ToolUtils.levenshtein` helper that v0.5.8 already extracted for inner-tool typo paths (`create_resource` class names, `connect_signal` signal names).
- **Godot bridge addon v0.5.8** with three rounds of hardening + test backfill:
  - `tools/execute` now distinguishes a tool that halted (null return — likely an unhandled runtime error) from a tool that returned the wrong shape, and `push_error`s either case to the editor Output panel so the user can correlate with the underlying stack trace. Previously both collapsed to a generic "returned non-Dictionary" message.
  - `context/gather` is now atomic: `success=false` when any sub-fetch (project info, scene tree) fails, with the failed source list baked into `message`/`error`. Previously the aggregator returned `success=true` even when sub-tools failed, so a client that only checked the top-level flag could silently consume incomplete context.
  - `PlaySessionManager` now mirrors active session PIDs to `user://gladekit-godot-bridge/sessions.json` and reaps orphan processes on bridge startup. Plugin hot-reload (editing any addon `.gd` file) previously orphaned the running `godot` subprocess because static state was reset; the bridge now kills the survivor on the next start.
  - `set_node_transform` refuses calls with none of position/rotation/scale (was silent no-op).
  - `BackupManager` now `push_error`s once-per-session if `ProjectSettings.globalize_path("res://")` returns empty (a hard editor-state failure that would otherwise silently disable all backups + the revert flow). New `BackupManager.is_available()` lets callers preflight before committing to a mutation turn.
  - `get_runtime_events` now mentions ring-buffer overflow in the `message` field when `dropped_due_to_overflow > 0`, so a noisy session can't silently truncate the visible event tail.
  - **New tests**: `test_ui_tools.gd` (14 tests across all 6 UI/Control tools — previously the entire category had zero coverage), `test_uid_tools.gd` (Godot 4.4+ ResourceUID, version-gated to skip cleanly on 4.3), and `test_ws_e2e.gd` (boots a real WS server + sends real JSON frames through `WebSocketPeer` — the first true end-to-end transport-pipeline test).
  - **Code quality**: extracted `parse_color_arg` and `levenshtein` into `ToolUtils`, removing five duplicate `_color_from` implementations and two duplicate `_levenshtein` implementations across `resource/`, `camera/`, and `signal/` tools.
## [0.7.5] - 2026-06-03

### Added

- **`create_script` overwrite guard.** Sibling hole to the shipped `modify_script` gate — previously a model could clobber any real project script by calling `create_script` with a colliding path. The bridge now refuses `create_script` when the target path already exists on disk and was not created in the current session via `create_script`, unless the caller passes `confirmExistingFileModification=true` (same flag name as `modify_script` so the agent learns one pattern). Schema description updated lockstep on the MCP server so clients see the new arg + the new behavior contract.
- **Godot bridge addon v0.4.6** with the new `context/gather` endpoint: one round-trip returns project metadata + scene tree (including the model-friendly flat `tree_text`) + recent-error history. Replaces the 2–3 separate `tools/execute` calls a fresh session would otherwise need to orient the agent. MCP clients can call it directly if they want the same aggregation.
- **Godot bridge addon v0.4.5** with `create_resource` — generic factory for any concrete Resource subclass (BoxMesh, Shape3D variants, Curve, Environment, AudioStream, Gradient, …). Composition partner to the v0.4.4 `set_node_resource`: create the `.tres` here, then assign it there. Refuses Material/Script types with a redirect to the dedicated creators so the three resource creators stay cleanly partitioned.

## [0.7.4] - 2026-06-01

### Added

- **`create_resource` Godot tool.** Generic factory for any concrete `Resource` subclass — `BoxMesh`, every `Shape3D`, `Curve`/`Curve2D`/`Curve3D`, `Environment`, `AudioStream` subclasses, `Gradient`/`GradientTexture*`, and more. Composition partner to the v0.4.4 `set_node_resource`: create the `.tres` here, then assign it there. Refuses `Material`/`Script` types with a redirect to `create_material`/`create_script` so the three resource creators stay cleanly partitioned. On unknown class names returns up to 5 edit-distance-ranked suggestions; on abstract types returns concrete subclasses. Ships with Godot bridge addon **v0.4.5**.

## [0.7.3] - 2026-06-01

### Fixed

- Re-publish after a PyPI trusted-publisher hiccup blocked the 0.7.2 upload. No code changes from 0.7.2.

## [0.7.2] - 2026-06-01

### Added

- **`get_project_info` Godot tool.** Single-call snapshot of a Godot project: name, version, renderer, main scene, currently edited scene, counts of scenes/scripts/resources, enabled addons, and (in `response_format="detailed"`) bounded file listings, top-level directories, and the project's custom input actions (engine builtins like `ui_accept` are filtered out). Replaces the 4-5 exploratory calls an agent typically makes when dropped into an unfamiliar project. Read-only and safe in play mode.
- **3 Godot signal-wiring tools** for editor-time, scene-saved (CONNECT_PERSIST) signal connections — the same kind of wiring you'd otherwise make through the Godot editor's Node panel:
  - `connect_signal` — wire an emitter's signal to a target method (idempotent; refuses to wire nonexistent signals or methods with closest-match suggestions).
  - `list_signal_connections` — read existing wiring on a node; `response_format="detailed"` also lists every signal declared on the node.
  - `disconnect_signal` — remove a persistent connection; never silently no-ops.
- **`set_node_resource` Godot tool** (bridge v0.4.4). Assign a Resource loaded from a `res://` path to any Resource-typed property on a node. One consolidated tool instead of a separate `assign_*` per resource kind.

### Fixed

- **Godot bridge `/health` endpoint reported the wrong version.** A hardcoded version constant in the bridge silently drifted from `plugin.cfg` during a bump, so up-to-date users saw false "stale bridge" warnings from the MCP server. The bridge now reads its version dynamically from `plugin.cfg` at startup, and a regression-guard test refuses to merge any future hardcoded version constant.
- **`connect_signal` typo suggestions are much more useful.** A 1-character typo like `timeput` (for `timeout`) or `request_redy` (for `request_ready`) now returns the actual closest match instead of an alphabetical fallback. Uses Levenshtein edit-distance matching with a noise filter that drops weak runners-up when the top match is clearly correct.
- **`connect_signal` schema description** for `method_name` now correctly notes that built-in class methods (`queue_free`, `request_ready`, etc.) are valid targets, not just script-declared methods. The previous wording would have steered agents away from a working path.

## [0.7.1] - 2026-05-29

### Added

- **Godot engine support (4.3+).** The MCP server now drives the Godot editor in addition to Unity. On startup it probes the local bridges and exposes the matching tool set — Unity if the Unity bridge is reachable on `:8765`, Godot if the Godot bridge is reachable on `:8766`. Set `GLADEKIT_MCP_FORCE_ENGINE=unity|godot` to skip the probe and pin an engine (useful when both editors are open).
- **33 native Godot tools** across scene/node (create/find/transform/reparent/duplicate/delete nodes), GDScript (create/modify/read/find scripts + node attachment), camera & light, resources (materials), physics bodies, scene I/O (`.tscn` create/open/save/instantiate), a live play-session loop (`run_project` → `get_debug_output` → `stop_project`), and Godot 4.4+ `ResourceUID` handling.
- **Godot bridge addon** (`com.gladekit.mcp-bridge` for Godot, v0.3.1) — a thread-based WebSocket server for the Godot editor, installed by copying into `addons/`. See the README's Godot Quick Start.

### Notes

- Unity behavior is unchanged: the Unity HTTP path is byte-identical, and a session with no engine declared defaults to Unity. Existing Unity clients require no changes.
- `0.7.0` was tagged but never published — a CI-only test that assumed the Godot bridge sources sit alongside `mcp-server/` failed in the published-repo layout (they ship from a separate repo). The test now skips when those sources are absent; `0.7.1` is the first published release with Godot support.

## [0.6.8] - 2026-05-28

### Fixed

- **0.6.7 bridge install fails to compile in fresh UPM clients.** The two new files (`BridgeDiagnostics.cs`, `BridgeDiagnostics_RingBuffer.cs`) shipped without their `.meta` siblings. Unity's PackageCache is immutable, so missing meta files cause the assets to be silently dropped on import — the `BridgeDiagnostics` type ceases to exist and `GladeKitMCPWindow.cs` fails with CS0246. Adds the meta files. No other changes from 0.6.7.

## [0.6.7] - 2026-05-28

### Fixed

- **`compile_scripts` no longer surfaces a false `ReadTimeout` and wedge the bridge on large projects.** On projects with thousands of assets or pending imports, the bridge's `AssetDatabase.Refresh()` call inside `compile_scripts` can block the Unity main thread for well past the default 30s HTTP timeout. The MCP client would surface `Unity bridge error for compile_scripts: ReadTimeout`, then every retry would queue behind the still-running Refresh and time out the same way — making the bridge appear permanently stuck until the Editor was restarted. A per-tool override in the dispatcher now gives `compile_scripts` 180s, which matches the actual cost on a cold scene-open without removing the finite ceiling.

### Added

- **`Restart` button in `Window > GladeKit MCP`.** Stops and restarts the bridge HTTP server in one click — drains any in-flight async tool handles and queued requests before rebinding to `localhost:8765`. Use this when the bridge appears unresponsive instead of restarting the entire Unity Editor.
- **Bridge Diagnostics panel in `Window > GladeKit MCP`.** A 50-entry ring buffer of bridge lifecycle and fault events (server start/stop/restart, HTTP request errors, tool execution faults, async-deadline hits) rendered newest-first with absolute and relative timestamps. Makes wedged-bridge incidents self-diagnosing without scraping the Unity Console. Cleared on Editor domain reload — fresh sessions start clean.

## [0.6.1] - 2026-05-13

### Fixed

- **Semantic search no longer crashes the server on a broken install env.** `numpy` and `openai` are now lazy-imported inside `search.py` instead of at module load. If either is missing (e.g. a `uv tool install` whose env was never refreshed after a dependency was added, or a platform where numpy fails to build), the MCP server still starts — semantic search auto-disables with a clear stderr warning instead of taking the whole server down with `ModuleNotFoundError: No module named 'numpy'`.
- **`import_asset` no longer surfaces a false "import failed" error on multi-MB Kenney packs.** The default 30s HTTP timeout was too short for download + extract + per-file Unity importer config + `AssetDatabase.Refresh()`. A per-tool override in the dispatcher now gives `import_asset` 300s, which matches the actual work it does. Previously, the MCP client would time out and report failure even when the Unity bridge eventually completed the import successfully.
- **Bridge HTTP errors with empty `__str__` now surface the exception class name.** `httpx.ReadTimeout` and `httpx.ConnectError` sometimes raise without a message string, which produced `"Unity bridge error for import_asset: "` with an empty tail. The bridge dispatcher now falls back to the exception type name (`"Unity bridge error for import_asset: ReadTimeout"`) so failures are self-diagnosing.

### Changed

- Tightened the `find_asset` tool description so LLM clients route asset-discovery requests to the bundled CC0 catalog instead of defaulting to web search. No behavioral or schema change — description-only.

## [0.5.2] - 2026-05-10

### Fixed

- **Bundled Kenney catalog now ships with working download URLs.** v0.5.1 shipped a catalog with every `download_url` field set to `null`, so `import_asset` calls failed for all 17 packs. 13 of 17 packs now have resolved URLs; the remaining 4 are flagged for the next `scripts/build_kenney_index.py` refresh.
- Corrected the catalog `notes` field that incorrectly described the runtime provider as scraping `official_page` at fetch time. The provider reads pre-baked `download_url` values from the catalog; the refresh script (`scripts/build_kenney_index.py`) is the only component that scrapes, and it runs at index-refresh time, not at request time.
- `_reload_tools_pkg` test helper now also clears the cached `tools` attribute on the parent `gladekit_mcp` package, so the `GLADEKIT_MCP_DISABLE_ASSET_PIPELINE` env-var toggle is actually re-read across test cases.

### Added

- **Asset pipeline (3 new tools).** Find and import free CC0 assets directly from your AI client; ships with a [Kenney.nl](https://kenney.nl) catalog and orchestrator bundled into the MCP server (no cloud dependency).
  - `find_asset` — read-only search across asset providers. Returns ranked candidates with name, description, license, license summary, official page, approximate asset count, and a relevance score. Filterable by `asset_type` (`sprite_2d` / `model_3d` / `audio_sfx` / `audio_music` / `animation` / `ui_sprite`), free-text `style` (`pixel art`, `vector`, `low-poly`, `voxel`), explicit `tags`, and `license_constraint`. Runs entirely against the bundled Kenney catalog — works offline.
  - `import_asset` — downloads the resolved asset, extracts (zip) into `Assets/<targetPath>/`, configures Unity import settings for the asset type (`TextureImporter` for sprites with pixel-art-friendly defaults — Sprite mode, Point filter, Uncompressed; `ModelImporter` for 3D; `AudioImporter` for audio), and writes a `.gladekit-asset.json` sidecar with license metadata. Requires explicit `licenseAcknowledged: true`.
  - `list_imported_assets` — read-only audit. Walks `.gladekit-asset.json` sidecars under `Assets/`, returns license counts and attribution-required count. Supports `licenseFilter` to filter by a specific license. Useful before a commercial release.
- **Bundled orchestrator (`gladekit_mcp.asset_pipeline/`).** Self-contained search and URL resolution — the asset pipeline runs entirely inside the MCP server with no external service dependency.
- **Two layers of toggle for studios with curated-asset workflows:**
  - **MCP server:** set `GLADEKIT_MCP_DISABLE_ASSET_PIPELINE=1` in the server environment. The three tools are stripped from the tool list and dispatch refuses with a clear error.
  - **Unity bridge:** `EditorPrefs["GladeAI.AssetPipelineEnabled"]` (default `true`). Toggleable via `POST /api/settings { "assetPipelineEnabled": false }`. Enforced by `AssetPipelineGuard` on every asset-pipeline tool — defense-in-depth in case a misconfigured client makes it through.
  - The state is also surfaced on `GET /api/health` as `assetPipelineEnabled` so clients can detect and reflect the bridge-side setting.
- **License + attribution discipline.** Every imported asset bundle gets a `.gladekit-asset.json` sidecar recording: candidate id, provider, license, attribution string, source URL, import timestamp, asset type, target path, and imported file paths. `list_imported_assets` reads these to surface required attributions before shipping.

### Security

- **The LLM never sees download URLs.** `import_asset` accepts `candidateId` from the LLM; the MCP server's preprocessor calls the orchestrator to resolve the actual download URL and injects it into the bridge call as underscore-prefixed fields the schema does not advertise. Any LLM attempt to set `_resolvedUrl` / `_resolvedLicense` / etc. is stripped before the orchestrator lookup, so a fabricated URL never survives even when resolution fails.
- **License acknowledgment is a hard gate.** Both the MCP-side preprocessor and the Unity bridge tool require `licenseAcknowledged: true` and refuse with a clear error otherwise. Set this only after the user has explicitly accepted the license shown by `find_asset`.
- **Bridge-side URL host allowlist (defense in depth).** Even if a client bypasses both the cloud and MCP preprocessors and sends `import_asset` directly to the bridge with a forged `_resolvedUrl`, the bridge refuses to download from any host outside the per-provider allowlist in `AssetPipelineGuard.IsResolvedUrlHostAllowed` (Kenney → `kenney.nl` / `www.kenney.nl`, HTTPS only). Adding a new provider to the orchestrator requires adding its hosts here too — the bridge fails closed on unknown providers.

### Notes

- v1 ships Kenney.nl only. Additional providers (Freesound for SFX, Quaternius / Poly Pizza for 3D, AI generation via Replicate / PixelLab / Meshy / ElevenLabs) are on the roadmap.
- Tool count is now 235+ across 16 categories (was 230+ across 15).

## [0.5.0] - 2026-05-05

### Added

- **Runtime / Live Loop tools (5 new).** A small surface for agents that want to watch a Unity Play session for runtime errors and orchestrate fixes:
  - `start_runtime_observation` / `stop_runtime_observation` — arm/disarm runtime-event capture; the start call snapshots a baseline cursor so you only get events from arming forward.
  - `get_runtime_events` — incremental cursor-based poll for `Error` / `Exception` log entries during Play Mode. Returns events with a stable per-event fingerprint (`condition + first 500 chars of stack`) plus `playModeActive`, `observationActive`, and `nextCursor` for the next call.
  - `get_play_mode_state` — read-only snapshot of Play Mode state (isPlaying, last enter/exit timestamps, observation arming status). Useful for "watch for Play exit then act" flows.
  - `apply_queued_fix` — idempotent multi-step fix dispatcher keyed on `proposalId`. Each `change` is a `{toolName, args, rationale}` triple dispatched through the same path as direct tool calls (so DemoAssetsGuard and SessionTracker hooks fire uniformly). A second call with the same `proposalId` returns `alreadyApplied:true` with the prior result instead of re-executing — safe for retry-on-blip flows.
- **Bridge services to back the Runtime tools (in `unity-bridge/`):** `RuntimeLogStream` (500-entry ring buffer with monotonic cursors and condition-only legacy drain for the existing `/api/console/events` endpoint), `PlayModeObserver` (Play Mode lifecycle tracker, survives domain reload), and `FixApplyTracker` (idempotency registry capped at 200 entries).
- New `runtime` tool category exposed via the standard category-aware filter; the 5 tools are also added to `CORE_TOOLS` so they appear in Claude Code's default tool list.

### Changed

- **`/api/console/events` endpoint behavior change (internal, wire-compatible).** The legacy drain no longer mutates the ring buffer — it tracks a per-server `_legacyDrainCursor` and returns events past it. This lets cursor-based consumers (`get_runtime_events`) and the legacy drain coexist without stealing events from each other. The HTTP response shape is unchanged.
- **`UnityBridgeServer` slimmed by ~50 LOC.** The inline `Application.logMessageReceivedThreaded` subscription + 50-entry queue moved into `RuntimeLogStream`. The bridge static ctor no longer hooks the log event itself.

### Notes

- `propose_fix` is intentionally NOT exposed via the MCP server — the bridge has no handler for it. MCP clients should construct fix payloads themselves and dispatch via `apply_queued_fix` directly.

## [0.4.5] - 2026-05-03

### Changed

- **`gladekit version` now suggests the right upgrade command for your install method.** uvx (the recommended install path) caches resolved versions and won't pick up new releases without `--refresh`, but the previous output unconditionally said `pip install --upgrade gladekit-mcp` — which strands uvx users (pip often isn't on PATH, and the suggested command wouldn't update the cached uvx env even if it ran). Now detects uvx-managed envs via `sys.executable` and prints `uvx --refresh gladekit-mcp` instead.

## [0.4.4] - 2026-05-03

### Fixed

- **Duplicate `compile_scripts` tool name broke Windsurf.** The schema was registered in both `tools/core.py` and `tools/scripting.py`; the aggregator concatenated both, so MCP `tools/list` returned the same name twice. Claude Code tolerated it, but Windsurf strictly enforces the MCP spec's "unique tool names" rule and bricked the chat with `Duplicate tool name: mcp_*_compile_scripts` until the server was disabled. Removed the stub in `core.py` (kept the richer `scripting.py` definition). Reported by an OSS user against `gladekit-mcp` v0.4.2/v0.4.3.

### Changed

- **Defense-in-depth dedupe in `registry.get_mcp_tools()`.** Now dedupes by name (keeping the first occurrence) and emits a `logger.warning` on collision, so a future regression keeps the wire MCP-compliant and surfaces the bug instead of breaking strict clients.
- **`test_no_duplicate_tool_names` is now strict** — previously allowlisted `compile_scripts` as a "known duplicate". Any future duplicate fails CI.

## [0.4.3] - 2026-04-30

### Fixed

- **Six more mutating tools no longer silently drop nested-array args.** Fifth pass of the input-resolution audit. Each tool received a `transforms`/`maps`/`axes`/`motions`/`spriteOrder` array via the schema, but the bridge's flat JSON parser left nested arrays as raw strings — the `is List<object>` type-check then silently failed when the call routed through `batch_execute`. Affected tools: `set_transform_batch`, `set_input_action_bindings`, `ensure_legacy_input_axes`, `create_blend_tree_1d`, `create_blend_tree_2d`, `create_sprite_animation_clip`. All now re-hydrate via `TryParseJsonArrayToList` matching the convention from the fourth pass.
- **`set_input_action_bindings` was the worst silent-success case** — returned `"Updated InputActionAsset bindings"` while applying nothing. Now returns structured `mapsUpdated` / `actionsUpdated` / `bindingsAdded` counts and recursively re-hydrates the nested `actions` and `bindings` arrays inside each map. Live verification surfaced two additional pre-existing bugs in this tool that the deep-parse fix made reachable for the first time: (1) `FindActionMap(name, throwIfNotFound: true)` throws instead of returning null, defeating the `?? AddActionMap` find-or-create fallback (changed to default `false`); (2) `.inputactions` files serialize as JSON, not YAML — `EditorUtility.SetDirty + AssetDatabase.SaveAssets` was a silent no-op for the file. Now persists via `asset.ToJson()` + `File.WriteAllText` + `AssetDatabase.ImportAsset`.
- **`create_blend_tree_1d` / `create_blend_tree_2d` surface skipped motions.** Previously returned `success=true, motionCount=0` when motions were requested but failed to resolve (silent failure mode the audit is designed to catch). Now return structured `skippedMotions` per-entry reasons (`clipPath is required`, `AnimationClip not found at clipPath`) and **error** when `requestedMotions > 0 && motionCount == 0`.

## [0.4.2] - 2026-04-30

### Fixed

- **`set_animation_clip_curves` no longer silently drops curves.** The Python schema advertised `componentType` and `keys` while the C# bridge read `type` and `keyframes` — clients following the schema got every curve dropped with success message "Set 0 curve(s)". The bridge now accepts both naming variants for forward compatibility, and curves that fail to land surface a structured `skippedCurves` array with per-entry reasons.
- **Type strings now resolve from short names.** `Transform`, `SpriteRenderer`, `GameObject`, etc. are accepted alongside fully-qualified names. The previous `System.Type.GetType` lookup silently returned null for short names, dropping the curve.
- **Zero-applied-with-skips now returns an error.** Calls that produce `curvesAdded=0` but had per-entry skip reasons return `success=false` instead of a misleading success.
- **`get_animation_clip_curves` reads back curves correctly.** It was walking SerializedObject fields that don't exist (`propertyName`/`type` vs the actual `attribute`/`classID`), returning empty for clips that had data. Replaced with the canonical `AnimationUtility.GetCurveBindings` API.
- **`set_animation_curve_tangents` accepts non-Transform bindings.** Optional `type` arg lets callers tangent-tune `SpriteRenderer`, `MeshRenderer`, or custom MonoBehaviour curves. On a curve miss, the response enumerates up to 20 actual clip bindings as `path|propertyName|type` strings so the next call can target a real one.
- **`remove_animation_clip_curves` distinguishes failure modes.** Returns structured per-entry skip reasons distinguishing `unresolvedType` from `notFoundOnClip`.
- **`set_sprite_animation_curves` reports skipped frames.** Per-keyframe skip tracking with `similarSprites` hints (filename-based search across `t:Sprite` then `t:Texture2D`) when a sprite asset can't be loaded. Returns `success=false` when zero keyframes parse.

### Internal

- All three setters now re-hydrate JSON-array args via `TryParseJsonArrayToList`. The bridge's flat JSON parser leaves nested arrays as raw strings; the previous `is List<object>` check silently failed for any caller routed through `batch_execute`.

## [0.3.0] - 2026-04-18

### Changed

- **`openai` and `numpy` are now default dependencies.** Script semantic search works out of the box as soon as `OPENAI_API_KEY` is set — no install flags needed. Previously these packages shipped behind the `[search]` extra, which caused silent fallback to unranked results when users set the key without first reinstalling with the extra.

### Removed

- **Dropped `[search]` and `[all]` optional-dependency extras.** They are now redundant. If your install command includes `gladekit-mcp[search]` or `gladekit-mcp[all]`, drop the suffix — plain `gladekit-mcp` now bundles everything the `[search]` extra contained. The `[http]` extra is retained for explicit pinning of `starlette`/`uvicorn`.

### Migration

No config changes required. If you previously launched the server with:

```json
{ "command": "uvx", "args": ["gladekit-mcp[search]"] }
```

simplify to:

```json
{ "command": "uvx", "args": ["gladekit-mcp"] }
```

Semantic search activates automatically when `OPENAI_API_KEY` is present in the `env` block.
