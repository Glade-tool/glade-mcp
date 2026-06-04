extends GutTest

# Validates the explicit tool registry: lookup, count, duplicate detection,
# empty-name rejection. No editor dependencies.

const ToolRegistry = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd")
const ITool = preload("res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd")


class _StubTool extends ITool:
	func _init(n: String) -> void:
		tool_name = n
		requires_edit_mode = false

	func execute(_args: Dictionary) -> Dictionary:
		return {"success": true, "message": "stub"}


# ── Registry self-population from preloads ────────────────────────────────

func test_registry_contains_all_mvp_tools() -> void:
	var registry = ToolRegistry.new()
	# Phase 2 scene/node (11, incl. set_node_resource) + script (5) = 16;
	# Phase 3 camera/light (2) + resource (2) + physics (1) + scene_io (4)
	# + runtime (7) + uid (2) = 18; Phase 5 signal (3); create_resource (1);
	# project introspection get_project_info + list_assets (2) = 40;
	# v0.5.0 UI/Control (6) = 46; v0.5.2 structured runtime-event
	# observation (3) = 49; v0.5.3 lighting & environment (4 — set/get
	# light_properties + set/get world_environment) = 53;
	# v0.6.0 animation (5 — add_animation_to_player + add_animation_track +
	# add_animation_keyframe + set_animation_properties +
	# get_animation_player_info) = 58; add_input_action (1) = 59 total.
	assert_eq(registry.get_tool_count(), 59, "Catalog should register exactly 59 tools")

	# Critical names that must be present for the schema-mock layer to wire
	# up correctly. Failing here means a registration line went missing.
	var expected_names := [
		# Phase 2 — Scene / Node
		"get_scene_tree", "get_node_info", "find_nodes", "create_node",
		"create_primitive_3d", "delete_node", "rename_node", "duplicate_node",
		"set_node_parent", "set_node_transform", "set_node_resource",
		# Phase 2 — Script
		"create_script", "modify_script", "get_script_content", "find_scripts",
		"attach_script_to_node",
		# Phase 3 — Camera / Light
		"create_camera_3d", "create_light",
		# Phase 3 — Resource
		"create_material", "set_material_property", "create_resource",
		# Phase 3 — Physics
		"create_physics_body",
		# Phase 3 — Scene I/O
		"create_scene", "open_scene", "save_scene", "instantiate_scene",
		# Phase 3 — Runtime / process
		"get_play_mode_state", "get_selection", "get_godot_console_logs",
		"run_project", "stop_project", "get_debug_output", "launch_editor",
		# Phase 3 — UID (4.4+)
		"get_uid", "update_project_uids",
		# Phase 5 — Signal wiring (persistent, scene-saved)
		"connect_signal", "list_signal_connections", "disconnect_signal",
		# Project introspection + input map
		"get_project_info", "list_assets", "add_input_action",
		# v0.5.0 — UI / Control
		"create_control", "set_control_anchors", "set_control_text",
		"set_control_size", "list_ui_hierarchy", "create_theme",
		# v0.5.2 — Structured runtime-event observation
		"start_runtime_observation", "stop_runtime_observation",
		"get_runtime_events",
		# v0.5.3 — Lighting & environment
		"set_light_properties", "get_light_info",
		"set_world_environment", "get_world_environment",
		# v0.6.0 — Animation
		"add_animation_to_player", "add_animation_track",
		"add_animation_keyframe", "set_animation_properties",
		"get_animation_player_info",
	]
	for expected in expected_names:
		assert_true(registry.has_tool(expected), "Missing registration for tool '%s'" % expected)


func test_get_tool_returns_instance() -> void:
	var registry = ToolRegistry.new()
	var t = registry.get_tool("get_scene_tree")
	assert_not_null(t)
	assert_eq(t.tool_name, "get_scene_tree")


func test_get_tool_unknown_returns_null() -> void:
	var registry = ToolRegistry.new()
	assert_null(registry.get_tool("not_a_real_tool"))


func test_get_tool_names_sorted() -> void:
	var registry = ToolRegistry.new()
	var names := registry.get_tool_names()
	var sorted_copy := names.duplicate()
	sorted_copy.sort()
	assert_eq(names, sorted_copy, "get_tool_names() must return sorted output")


# ── register_tool guards ──────────────────────────────────────────────────

func test_register_tool_rejects_empty_name() -> void:
	var registry = ToolRegistry.new()
	var initial: int = registry.get_tool_count()
	# Suppress the push_error so it doesn't fail the GUT run.
	registry.register_tool(_StubTool.new(""))
	assert_eq(registry.get_tool_count(), initial, "Empty-name registration must be a no-op")


func test_register_tool_rejects_duplicate() -> void:
	var registry = ToolRegistry.new()
	var initial: int = registry.get_tool_count()
	# Re-register get_scene_tree's name — should be rejected.
	registry.register_tool(_StubTool.new("get_scene_tree"))
	assert_eq(registry.get_tool_count(), initial, "Duplicate-name registration must be a no-op")
	# Original tool should still be the one stored.
	assert_eq(registry.get_tool("get_scene_tree").tool_name, "get_scene_tree")
