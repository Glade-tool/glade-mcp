extends RefCounted

# Explicit tool registration. Adding a new tool is two steps:
#   1. Create the tool .gd file extending i_tool.gd
#   2. Add a const + register_tool() call below
#
# We deliberately avoid scanning tools/implementations/ via DirAccess: the
# explicit list surfaces drift loudly (failing tests, missing const) instead
# of silently dropping a tool when its filename changes.

# ── Scene / Node tools (Phase 2) ───────────────────────────────────────────
const GetSceneTreeTool      = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/get_scene_tree.gd")
const GetNodeInfoTool       = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/get_node_info.gd")
const FindNodesTool         = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/find_nodes.gd")
const CreateNodeTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/create_node.gd")
const CreatePrimitive3DTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/create_primitive_3d.gd")
const CreateSprite2DTool    = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/create_sprite_2d.gd")
const CreateAnimatedSprite2DTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/create_animated_sprite_2d.gd")
const CreateTilemapLayerTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/create_tilemap_layer.gd")
const SetTilemapCellsTool   = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/set_tilemap_cells.gd")
const SetTilemapCollisionTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/set_tilemap_collision.gd")
const CreateParallax2DTool  = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/create_parallax_2d.gd")
const CreateMovingPlatformTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/create_moving_platform.gd")
const DeleteNodeTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/delete_node.gd")
const RenameNodeTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/rename_node.gd")
const DuplicateNodeTool     = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/duplicate_node.gd")
const SetNodeParentTool     = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/set_node_parent.gd")
const SetNodeTransformTool  = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/set_node_transform.gd")
# Layout primitive: position many nodes into a row/column/grid in one call
# (the batch counterpart of set_node_transform for level building).
const ArrangeNodesTool      = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/arrange_nodes.gd")
const SetNodeResourceTool   = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/set_node_resource.gd")
const SetNodePropertyTool   = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/set_node_property.gd")

# ── Script tools (Phase 2) ─────────────────────────────────────────────────
const CreateScriptTool       = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/create_script.gd")
const ModifyScriptTool       = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/modify_script.gd")
const GetScriptContentTool   = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/get_script_content.gd")
const FindScriptsTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/find_scripts.gd")
const FindReferencesTool     = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/find_references.gd")
const FindSceneUsagesTool    = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/find_scene_usages.gd")
const AttachScriptToNodeTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/attach_script_to_node.gd")
# Vetted-template scaffolder: writes a known-good CharacterBody3D controller +
# decoupled orbit camera verbatim, so the model can't re-derive the
# self-referential-camera bug. Lives in the script category (it's script-centric).
const CreateThirdPersonControllerTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/create_third_person_controller.gd")

# 2D analog of the above: a vetted CharacterBody2D platformer/top-down controller
# (style arg) that ships the game-feel details — coyote time, jump buffering,
# variable jump height — a model re-deriving movement from scratch tends to drop.
const Create2DControllerTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/create_2d_controller.gd")

# Vetted trauma-based Camera2D screen-shake scaffolder — the "juice" companion to
# create_particles_2d. Writes a known-good shake script (decaying, noise-driven,
# applied via offset so it composes with a following camera) and attaches it.
const CreateScreenShakeTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/create_screen_shake.gd")

# Per-object juice: a reusable tween component (scale pop / hit flash / fade /
# idle loop) parented under any Node2D/Control. The per-object counterpart to
# create_screen_shake's camera kick; composes with collectible/hazard/enemy.
const CreateJuiceTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/create_juice.gd")

# Vetted scene-transition overlay registered as an AUTOLOAD (must be a singleton
# to survive change_scene_to_file): fade-out → swap → fade-in, plus fade/flash
# helpers. Turns the menu/win/death hard scene CUTS into smooth fades.
const CreateSceneTransitionTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/create_scene_transition.gd")

# 2D gameplay-loop family: vetted scaffolders that turn a playable character into
# a winnable/losable game. create_game_manager is the hub (score/lives/respawn/
# win-lose + HUD, reached via the "game_manager" group); create_collectible and
# create_hazard are Area2D pickups/dangers that wire into it.
const CreateGameManagerTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/create_game_manager.gd")
const CreateCollectibleTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/create_collectible.gd")
const CreateHazardTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/create_hazard.gd")
const CreateEnemy2DTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/create_enemy_2d.gd")

# 3D analog of create_enemy_2d: a vetted CharacterBody3D enemy (patrol/chaser/guard
# styles, same stomp + group wiring) for scenes with a Node3D root. Each tool
# refuses to run in the other's dimension.
const CreateEnemy3DTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/create_enemy_3d.gd")

# The shoot verb: a vetted projectile (flying Area2D/3D that travels, damages a
# target group, and self-frees) + a Shooter child node that spawns one on an input
# action. Dimension-aware via space inference. Composes with create_enemy_* and
# create_health.
const CreateProjectileTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/create_projectile.gd")

# Reusable HP component: a "Health" child node (space-agnostic) with take_damage/
# heal + damaged/healed/died signals and i-frames. Projectiles auto-route damage to
# it, turning one-shot-destroy into real multi-hit HP. Completes the combat loop.
const CreateHealthTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/create_health.gd")

# ── Camera / Lighting / Environment tools (Phase 3 + v0.5.3) ───────────────
# create_camera is dimension-aware (space="2d"|"3d"); the legacy create_camera_3d
# name is kept as a registry alias (see _register_aliases).
const CreateCameraTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/camera/create_camera.gd")
const CreateLightTool         = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/camera/create_light.gd")
const SetLightPropertiesTool  = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/camera/set_light_properties.gd")
const GetLightInfoTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/camera/get_light_info.gd")
const SetWorldEnvironmentTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/camera/set_world_environment.gd")
const GetWorldEnvironmentTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/camera/get_world_environment.gd")
const LookAtGameViewTool      = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/camera/look_at_game_view.gd")

# ── Resource tools (Phase 3 + 7) ───────────────────────────────────────────
const CreateMaterialTool      = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/resource/create_material.gd")
const SetMaterialPropertyTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/resource/set_material_property.gd")
const CreateResourceTool      = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/resource/create_resource.gd")

# ── Physics tools (Phase 3) ────────────────────────────────────────────────
const CreatePhysicsBodyTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/physics/create_physics_body.gd")
# Spatial query: cast a ray through the edited scene's physics space and report
# the first collider hit. Works at edit time (no play session needed).
const RaycastTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/physics/raycast.gd")
# Spatial query: find every collider overlapping a sphere/box at a point — the
# volume counterpart of raycast. Also edit-time (no play session needed).
const OverlapShapeTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/physics/overlap_shape.gd")

# ── Particles / juice ──────────────────────────────────────────────────────
# Preset-driven GPUParticles2D/3D + ParticleProcessMaterial scaffolder (explosion /
# sparkle / smoke / fire / trail) — the highest-impact "juice" lever.
const CreateParticles2DTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/particles/create_particles_2d.gd")
const CreateParticles3DTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/particles/create_particles_3d.gd")
const SetParticlesPropertiesTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/particles/set_particles_properties.gd")

# ── Scene I/O tools (Phase 3) ──────────────────────────────────────────────
const CreateSceneTool      = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene_io/create_scene.gd")
const OpenSceneTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene_io/open_scene.gd")
const SaveSceneTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene_io/save_scene.gd")
const InstantiateSceneTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene_io/instantiate_scene.gd")

# ── Runtime / process tools (Phase 3) ──────────────────────────────────────
const GetPlayModeStateTool    = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/runtime/get_play_mode_state.gd")
const GetSelectionTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/runtime/get_selection.gd")
const GetGodotConsoleLogsTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/runtime/get_godot_console_logs.gd")
const RunProjectTool          = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/runtime/run_project.gd")
const StopProjectTool         = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/runtime/stop_project.gd")
const GetDebugOutputTool      = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/runtime/get_debug_output.gd")
const LaunchEditorTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/runtime/launch_editor.gd")

# ── Structured runtime-event observation (v0.5.2) ──────────────────────────
const StartRuntimeObservationTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/runtime/start_runtime_observation.gd")
const StopRuntimeObservationTool  = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/runtime/stop_runtime_observation.gd")
const GetRuntimeEventsTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/runtime/get_runtime_events.gd")

# ── UID tools (Phase 3, Godot 4.4+ only) ───────────────────────────────────
const GetUidTool            = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/uid/get_uid.gd")
const UpdateProjectUidsTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/uid/update_project_uids.gd")

# ── Signal tools (Phase 5) ─────────────────────────────────────────────────
const ConnectSignalTool         = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/signal/connect_signal.gd")
const ListSignalConnectionsTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/signal/list_signal_connections.gd")
const DisconnectSignalTool      = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/signal/disconnect_signal.gd")

# ── Project introspection tools ────────────────────────────────────────────
const GetProjectInfoTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/project/get_project_info.gd")
const ListAssetsTool            = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/project/list_assets.gd")
const AddInputActionTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/project/add_input_action.gd")

# ── UI / Control tools (v0.5.0) ────────────────────────────────────────────
const CreateControlTool      = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/ui/create_control.gd")
const SetControlAnchorsTool  = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/ui/set_control_anchors.gd")
const SetControlTextTool     = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/ui/set_control_text.gd")
const SetControlSizeTool     = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/ui/set_control_size.gd")
const ListUiHierarchyTool    = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/ui/list_ui_hierarchy.gd")
const CreateThemeTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/ui/create_theme.gd")

# ── Menu / scene-flow family (v0.7.x) ──────────────────────────────────────
# Vetted scaffolders for the connective tissue between levels — the front door
# and the in-game overlay. create_main_menu writes a standalone title-screen
# scene whose Play button change_scene_to_file's into the gameplay scene;
# create_pause_menu drops an Esc-toggled pause overlay (CanvasLayer, process_mode
# ALWAYS so it can un-pause itself) into the open scene, with a "quit to menu"
# that routes back to the menu scene. Together they turn one playable level into
# a complete game (title → play → pause → quit to title).
const CreateMainMenuTool     = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/ui/create_main_menu.gd")
const CreatePauseMenuTool    = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/ui/create_pause_menu.gd")

# Screen-space health bar: a CanvasLayer overlay (ProgressBar + current/max readout)
# that finds a create_health component (default the "player" group's) and follows
# its damaged/healed signals so HP is VISIBLE. The HUD half of the health system.
const CreateHealthBarTool    = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/ui/create_health_bar.gd")

# ── Animation tools (v0.6.0) ───────────────────────────────────────────────
# AnimationPlayer scaffolding: register Animation .tres files with a player,
# add tracks (value / position_3d / rotation_3d / scale_3d / method), insert
# keyframes, set per-Animation properties (length / loop_mode / step), and
# read player state for inspection. The AnimationPlayer node itself + the
# Animation .tres are created via existing create_node + create_resource —
# these 5 tools close the gap between "I have an empty player + an empty
# animation" and "I have a playable animation library."
const AddAnimationToPlayerTool   = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/animation/add_animation_to_player.gd")
const AddAnimationTrackTool      = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/animation/add_animation_track.gd")
const AddAnimationKeyframeTool   = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/animation/add_animation_keyframe.gd")
const SetAnimationPropertiesTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/animation/set_animation_properties.gd")
const GetAnimationPlayerInfoTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/animation/get_animation_player_info.gd")

# ── AnimationTree state-machine tools (v0.6.8) ─────────────────────────────
# Godot's state-machine animation controller — the analog of Unity's Animator
# Controller. Where the AnimationPlayer tools above scaffold individual clips,
# these wrap those clips into an AnimationNodeStateMachine of states +
# transitions so a character blends idle/walk/run/jump driven by travel() or
# advance conditions. create builds (optionally seeding states from the bound
# player); add_state/add_transition extend; get_*_info inspects.
const CreateAnimationTreeTool         = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/animation/create_animation_tree.gd")
const AddStateMachineStateTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/animation/add_state_machine_state.gd")
const AddStateMachineTransitionTool   = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/animation/add_state_machine_transition.gd")
const GetAnimationTreeInfoTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/animation/get_animation_tree_info.gd")

# ── AnimationTree blend-space tools (v0.7.3) ───────────────────────────────
# AnimationNodeBlendSpace2D — directional sprite animation from a single 2D
# vector. The blend-space twin of the state-machine tools above: where a state
# machine wires distinct states by transitions, a blend space picks/blends one
# action's per-facing clips by movement direction. Feed velocity.normalized()
# into parameters/blend_position; auto-seeds from up/down/left/right clip names.
const CreateBlendSpace2DTool          = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/animation/create_blend_space_2d.gd")
# AnimationNodeBlendSpace1D — locomotion animation (idle/walk/run) from a single
# scalar. The 1D sibling of the 2D blend space above: blend along ONE axis
# (typically speed) instead of a facing vector. Auto-seeds from idle/walk/run
# clip names; feed velocity.length()/max_speed into parameters/blend_position.
const CreateBlendSpace1DTool          = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/animation/create_blend_space_1d.gd")

# ── Asset pipeline tools (v0.7.0) ──────────────────────────────────────────
# Download + install external CC0 assets. import_asset is async (downloads on a
# worker thread); see i_tool.gd's async protocol + ws_server._drain_async_dispatches.
const ImportAssetTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/asset_pipeline/import_asset.gd")
const ListImportedAssetsTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/asset_pipeline/list_imported_assets.gd")

# ── Audio tools (v0.6.7) ───────────────────────────────────────────────────
# Place an audio player in the scene and wire an imported stream to it — the
# step between import_asset (downloads/imports audio) and a sound that plays.
# create_audio_player picks AudioStreamPlayer (non-positional, music/UI) or a
# positional AudioStreamPlayer2D/3D; set_audio_player_properties mutates one.
const CreateAudioPlayerTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/audio/create_audio_player.gd")
const SetAudioPlayerPropertiesTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/audio/set_audio_player_properties.gd")

# ── Navigation tools (3D) ──────────────────────────────────────────────────
# Pathfinding for 3D scenes — the foundation enemy/NPC AI needs. bake_navigation_mesh
# makes a scene's geometry walkable (NavigationRegion3D + baked NavigationMesh,
# group-sourced so no reparenting); add_navigation_agent drops a configured
# NavigationAgent3D on a body so it can path across that region. Both are 3D-only
# and refuse on a 2D root, mirroring create_enemy_3d's dimension guard. (2D nav,
# obstacles, and off-mesh links are deliberate follow-ups.)
const BakeNavigationMeshTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/navigation/bake_navigation_mesh.gd")
const AddNavigationAgentTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/navigation/add_navigation_agent.gd")

var _tools: Dictionary = {}

# Backward-compat name → tool instance. Aliases keep an OLD tool name dispatching
# after a tool is renamed/generalized (e.g. create_camera_3d → create_camera), so
# existing transcripts, external MCP callers, and saved sessions don't break.
# Aliases are deliberately INVISIBLE to get_tool_count() / get_tool_names() and
# to the schema catalog: the agent is steered to the canonical name, and the
# parity/catalog tests count canonical tools only. Resolution still finds them.
var _aliases: Dictionary = {}


func _init() -> void:
	_register_all()
	_register_aliases()


# Register legacy tool-name aliases AFTER _register_all so the canonical tools
# exist to point at. Each alias resolves to the same instance as its canonical
# tool.
func _register_aliases() -> void:
	register_alias("create_camera_3d", "create_camera")


func register_alias(alias_name: String, canonical_name: String) -> void:
	if not _tools.has(canonical_name):
		push_error("[GladeKit MCP Bridge] Alias '%s' targets unknown tool '%s'" % [alias_name, canonical_name])
		return
	if _tools.has(alias_name):
		push_error("[GladeKit MCP Bridge] Alias '%s' collides with a real tool name" % alias_name)
		return
	_aliases[alias_name] = _tools[canonical_name]


func _register_all() -> void:
	# Scene / Node (18)
	register_tool(GetSceneTreeTool.new())
	register_tool(GetNodeInfoTool.new())
	register_tool(FindNodesTool.new())
	register_tool(CreateNodeTool.new())
	register_tool(CreatePrimitive3DTool.new())
	register_tool(CreateSprite2DTool.new())
	register_tool(CreateAnimatedSprite2DTool.new())
	register_tool(CreateTilemapLayerTool.new())
	register_tool(SetTilemapCellsTool.new())
	register_tool(SetTilemapCollisionTool.new())
	register_tool(CreateParallax2DTool.new())
	register_tool(CreateMovingPlatformTool.new())
	register_tool(DeleteNodeTool.new())
	register_tool(RenameNodeTool.new())
	register_tool(DuplicateNodeTool.new())
	register_tool(SetNodeParentTool.new())
	register_tool(SetNodeTransformTool.new())
	register_tool(ArrangeNodesTool.new())
	register_tool(SetNodeResourceTool.new())
	register_tool(SetNodePropertyTool.new())
	# Script (14)
	register_tool(CreateScriptTool.new())
	register_tool(ModifyScriptTool.new())
	register_tool(GetScriptContentTool.new())
	register_tool(FindScriptsTool.new())
	register_tool(FindReferencesTool.new())
	register_tool(FindSceneUsagesTool.new())
	register_tool(AttachScriptToNodeTool.new())
	register_tool(CreateThirdPersonControllerTool.new())
	register_tool(Create2DControllerTool.new())
	register_tool(CreateScreenShakeTool.new())
	register_tool(CreateJuiceTool.new())
	register_tool(CreateSceneTransitionTool.new())
	register_tool(CreateGameManagerTool.new())
	register_tool(CreateCollectibleTool.new())
	register_tool(CreateHazardTool.new())
	register_tool(CreateEnemy2DTool.new())
	register_tool(CreateEnemy3DTool.new())
	register_tool(CreateProjectileTool.new())
	register_tool(CreateHealthTool.new())
	# Camera / Lighting / Environment (6) — 2 Phase 3 + 4 (v0.5.3)
	register_tool(CreateCameraTool.new())
	register_tool(CreateLightTool.new())
	register_tool(SetLightPropertiesTool.new())
	register_tool(GetLightInfoTool.new())
	register_tool(SetWorldEnvironmentTool.new())
	register_tool(GetWorldEnvironmentTool.new())
	register_tool(LookAtGameViewTool.new())
	# Resource (3) — Material has its own dedicated tool; create_resource
	# handles every other built-in Resource subclass (Mesh, Shape3D, Curve, etc.)
	register_tool(CreateMaterialTool.new())
	register_tool(SetMaterialPropertyTool.new())
	register_tool(CreateResourceTool.new())
	# Physics (3)
	register_tool(CreatePhysicsBodyTool.new())
	register_tool(RaycastTool.new())
	register_tool(OverlapShapeTool.new())
	# Particles / juice (1)
	register_tool(CreateParticles2DTool.new())
	register_tool(CreateParticles3DTool.new())
	register_tool(SetParticlesPropertiesTool.new())
	# Scene I/O (4)
	register_tool(CreateSceneTool.new())
	register_tool(OpenSceneTool.new())
	register_tool(SaveSceneTool.new())
	register_tool(InstantiateSceneTool.new())
	# Runtime / process (10) — 7 Phase 3 + 3 structured observation (v0.5.2)
	register_tool(GetPlayModeStateTool.new())
	register_tool(GetSelectionTool.new())
	register_tool(GetGodotConsoleLogsTool.new())
	register_tool(RunProjectTool.new())
	register_tool(StopProjectTool.new())
	register_tool(GetDebugOutputTool.new())
	register_tool(LaunchEditorTool.new())
	register_tool(StartRuntimeObservationTool.new())
	register_tool(StopRuntimeObservationTool.new())
	register_tool(GetRuntimeEventsTool.new())
	# UID (2, 4.4+)
	register_tool(GetUidTool.new())
	register_tool(UpdateProjectUidsTool.new())
	# Signal (3, Phase 5) — persistent (scene-saved) signal wiring
	register_tool(ConnectSignalTool.new())
	register_tool(ListSignalConnectionsTool.new())
	register_tool(DisconnectSignalTool.new())
	# Project introspection + input map (3)
	register_tool(GetProjectInfoTool.new())
	register_tool(ListAssetsTool.new())
	register_tool(AddInputActionTool.new())
	# UI / Control (6, v0.5.0)
	register_tool(CreateControlTool.new())
	register_tool(SetControlAnchorsTool.new())
	register_tool(SetControlTextTool.new())
	register_tool(SetControlSizeTool.new())
	register_tool(ListUiHierarchyTool.new())
	register_tool(CreateThemeTool.new())
	# Menu / scene-flow (2, v0.7.x) — title screen + pause overlay; the
	# connective tissue that makes a single level a complete game.
	register_tool(CreateMainMenuTool.new())
	register_tool(CreatePauseMenuTool.new())
	register_tool(CreateHealthBarTool.new())
	# Animation (5, v0.6.0)
	register_tool(AddAnimationToPlayerTool.new())
	register_tool(AddAnimationTrackTool.new())
	register_tool(AddAnimationKeyframeTool.new())
	register_tool(SetAnimationPropertiesTool.new())
	register_tool(GetAnimationPlayerInfoTool.new())
	# AnimationTree state machine (4, v0.6.8) — states + transitions over the
	# player's clips; the Animator-Controller analog.
	register_tool(CreateAnimationTreeTool.new())
	register_tool(AddStateMachineStateTool.new())
	register_tool(AddStateMachineTransitionTool.new())
	register_tool(GetAnimationTreeInfoTool.new())
	# AnimationTree blend space (2) — directional sprite animation from a 2D
	# vector via AnimationNodeBlendSpace2D (v0.7.3), plus locomotion (idle/walk/
	# run) from a single speed scalar via AnimationNodeBlendSpace1D (v0.7.5).
	register_tool(CreateBlendSpace2DTool.new())
	register_tool(CreateBlendSpace1DTool.new())
	# Asset pipeline (2, v0.7.0) — async external-asset download + install,
	# plus a read-only license audit of what's been imported.
	register_tool(ImportAssetTool.new())
	register_tool(ListImportedAssetsTool.new())
	# Audio (2, v0.6.7) — place a player in the scene + wire an imported
	# stream so audio actually plays. create + mutate pair.
	register_tool(CreateAudioPlayerTool.new())
	register_tool(SetAudioPlayerPropertiesTool.new())
	# Navigation (2) — 3D pathfinding: bake a walkable NavigationRegion3D +
	# add a NavigationAgent3D to a body. The substrate for navmesh enemy AI.
	register_tool(BakeNavigationMeshTool.new())
	register_tool(AddNavigationAgentTool.new())


func register_tool(tool_instance) -> void:
	# Defensive guard against null. The most common cause is a preloaded
	# script that failed to parse — preload() returns null, then `.new()`
	# blows up the surrounding _register_all() and silently drops every
	# tool registered after it. Bailing out with push_error keeps the rest
	# of the catalog intact and screams in the Godot Output panel so the
	# next person catches it before it ships.
	if tool_instance == null:
		push_error("[GladeKit MCP Bridge] register_tool received null — a tool script likely failed to parse. Check the Output panel for the original parse error.")
		return
	var n: String = tool_instance.tool_name
	if n.is_empty():
		push_error("[GladeKit MCP Bridge] Cannot register tool with empty name (instance: %s)" % tool_instance)
		return
	if _tools.has(n):
		push_error("[GladeKit MCP Bridge] Duplicate tool registration: '%s'" % n)
		return
	_tools[n] = tool_instance


func get_tool(tool_name: String):
	if _tools.has(tool_name):
		return _tools[tool_name]
	return _aliases.get(tool_name, null)


func has_tool(tool_name: String) -> bool:
	return _tools.has(tool_name) or _aliases.has(tool_name)


func get_tool_names() -> Array:
	var names: Array = _tools.keys()
	names.sort()
	return names


func get_tool_count() -> int:
	return _tools.size()
