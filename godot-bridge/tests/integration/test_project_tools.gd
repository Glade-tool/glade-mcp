extends GutTest

# Integration tests for get_project_info. Exercises the concise + detailed
# response shapes against the actual edited scene, validates project-metadata
# fields, and confirms the file-walk + truncation logic stays consistent.
#
# Most assertions check the contract (shape, types, expected fields) rather
# than exact values, because the dev project's content can drift over time
# without breaking the tool.

const Registry = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd")

var _registry = null


func before_each() -> void:
	_registry = Registry.new()


func after_each() -> void:
	_registry = null


func _run(args: Dictionary) -> Dictionary:
	var t = _registry.get_tool("get_project_info")
	assert_not_null(t, "get_project_info must be registered")
	return t.execute(args)


# ── Happy paths ───────────────────────────────────────────────────────────

func test_concise_default_returns_metadata_and_counts() -> void:
	var r := _run({})
	assert_true(r.success, "Concise call should succeed: %s" % r.get("message", ""))
	assert_true(r.has("project"))

	var p: Dictionary = r.project
	# Metadata fields exist and have plausible types.
	assert_true(p.has("name"))
	assert_true(p.has("godot_version"))
	assert_string_contains(String(p.godot_version), "4.")  # Should run on Godot 4.x
	assert_true(p.has("renderer"))
	assert_true(p.has("main_scene"))
	assert_true(p.has("current_scene"))
	assert_true(p.has("supports_uid"))
	assert_true(p.supports_uid is bool)

	# Counts are non-negative integers.
	assert_true(p.scene_count is int and p.scene_count >= 0, "scene_count: %s" % p.scene_count)
	assert_true(p.script_count is int and p.script_count >= 0, "script_count: %s" % p.script_count)
	assert_true(p.resource_count is int and p.resource_count >= 0, "resource_count: %s" % p.resource_count)

	# enabled_addons is an array. The MCP bridge itself is always enabled
	# during these tests (we're running inside it), so its addon dir must
	# appear in the list.
	assert_true(p.enabled_addons is Array, "enabled_addons should be an Array")
	var saw_bridge: bool = false
	for addon in p.enabled_addons:
		if String(addon).contains("com.gladekit.mcp-bridge"):
			saw_bridge = true
			break
	assert_true(saw_bridge, "Bridge addon should appear in enabled_addons (got %s)" % str(p.enabled_addons))


func test_concise_does_not_include_detailed_fields() -> void:
	# Concise mode should NOT include the detailed-only payload — that's
	# the whole point of the response_format split.
	var r := _run({"response_format": "concise"})
	assert_true(r.success)
	var p: Dictionary = r.project
	assert_false(p.has("scenes"), "Concise should not include scenes listing")
	assert_false(p.has("scripts"), "Concise should not include scripts listing")
	assert_false(p.has("resources"), "Concise should not include resources listing")
	assert_false(p.has("input_actions"), "Concise should not include input_actions")
	assert_false(p.has("top_level_dirs"), "Concise should not include top_level_dirs")


func test_detailed_adds_listings_and_truncation_flags() -> void:
	var r := _run({"response_format": "detailed"})
	assert_true(r.success)
	var p: Dictionary = r.project

	# Detailed-mode-only fields exist.
	for field in ["scenes", "scripts", "resources", "top_level_dirs",
				  "input_actions", "scenes_truncated", "scripts_truncated",
				  "resources_truncated"]:
		assert_true(p.has(field), "Detailed mode should include '%s'" % field)

	# Listings are arrays.
	assert_true(p.scenes is Array)
	assert_true(p.scripts is Array)
	assert_true(p.resources is Array)
	assert_true(p.top_level_dirs is Array)
	assert_true(p.input_actions is Array)

	# Counts vs. listings consistency — if not truncated, listing length
	# should equal the count.
	if not p.scenes_truncated:
		assert_eq(p.scenes.size(), p.scene_count, "scenes listing should match scene_count when not truncated")
	if not p.scripts_truncated:
		assert_eq(p.scripts.size(), p.script_count, "scripts listing should match script_count when not truncated")


func test_detailed_listings_have_expected_shape() -> void:
	var r := _run({"response_format": "detailed"})
	assert_true(r.success)
	var p: Dictionary = r.project
	# Scenes/scripts have {path, name}; resources additionally have {type}.
	for entry in p.scenes:
		assert_true(entry is Dictionary)
		assert_true(entry.has("path") and entry.has("name"))
		assert_string_contains(String(entry.path), "res://")
	for entry in p.scripts:
		assert_true(entry is Dictionary)
		assert_true(entry.has("path") and entry.has("name"))
	for entry in p.resources:
		assert_true(entry is Dictionary)
		assert_true(entry.has("path") and entry.has("format"))


func test_detailed_input_actions_filters_engine_builtins() -> void:
	# input_actions must only include actions actually saved in
	# project.godot's [input] section — never:
	#   - Engine `ui_*` defaults
	#   - In-editor shortcut namespaces (spatial_editor/, script_editor/, etc.)
	#   - Runtime-registered actions (those won't have PROPERTY_USAGE_STORAGE)
	var r := _run({"response_format": "detailed"})
	assert_true(r.success)
	var p: Dictionary = r.project
	for action_name in p.input_actions:
		var s := String(action_name)
		# Common ui_* defaults
		assert_false(
			s in ["ui_accept", "ui_cancel", "ui_left", "ui_right", "ui_up", "ui_down",
				  "ui_focus_next", "ui_text_submit"],
			"Engine ui_ default '%s' leaked into custom input_actions" % s,
		)
		# Editor namespaces (these come from live InputMap, not project.godot)
		assert_false(
			s.begins_with("spatial_editor/"),
			"Editor namespace '%s' leaked into custom input_actions" % s,
		)
		assert_false(
			s.begins_with("script_editor/"),
			"Editor namespace '%s' leaked into custom input_actions" % s,
		)


# ── Read-only invariant ──────────────────────────────────────────────────

func test_tool_is_marked_read_only() -> void:
	# This tool runs in both edit and play mode — the agent should be able
	# to call it any time to orient itself.
	var t = _registry.get_tool("get_project_info")
	assert_false(t.requires_edit_mode, "get_project_info must be safe in play mode")


# ── list_assets ───────────────────────────────────────────────────────────
# Contract-level checks: the tool walks the project and returns a sorted,
# typed asset list. Assertions avoid exact counts because the dev project's
# asset set drifts over time.

func _run_assets(args: Dictionary) -> Dictionary:
	var t = _registry.get_tool("list_assets")
	assert_not_null(t, "list_assets must be registered")
	return t.execute(args)


func test_list_assets_returns_typed_sorted_entries() -> void:
	var r := _run_assets({})
	assert_true(r.success, "list_assets should succeed: %s" % r.get("message", ""))
	assert_true(r.has("assets") and r.assets is Array, "assets must be an Array")
	assert_true(r.has("count") and r.count is int, "count must be an int")
	assert_true(r.has("truncated") and r.truncated is bool, "truncated must be a bool")
	assert_eq(r.count, r.assets.size(), "count must equal the assets array length")

	var prev := ""
	for entry in r.assets:
		assert_true(entry is Dictionary, "each asset must be a Dictionary")
		assert_true(entry.has("path") and entry.path is String, "asset needs a String path")
		assert_true(entry.has("type") and entry.type is String, "asset needs a String type")
		assert_true(String(entry.path).begins_with("res://"), "asset path must be a res:// URI")
		# Scripts are intentionally excluded — they have their own discovery.
		assert_false(String(entry.path).ends_with(".gd"), "list_assets must not return scripts")
		# Results are sorted by path.
		assert_true(prev <= String(entry.path), "assets must be sorted by path")
		prev = String(entry.path)


func test_list_assets_type_filter_restricts_results() -> void:
	# Whatever the project contains, filtering by "scene" must yield only
	# scene-typed entries (possibly none — that's still a valid result).
	var r := _run_assets({"type_filter": "scene"})
	assert_true(r.success)
	for entry in r.assets:
		assert_eq(String(entry.type), "scene", "type_filter=scene must only return scenes")


func test_list_assets_respects_max_results() -> void:
	var r := _run_assets({"max_results": 1})
	assert_true(r.success)
	assert_true(r.assets.size() <= 1, "max_results=1 must cap the list at one entry")


func test_list_assets_is_marked_read_only() -> void:
	var t = _registry.get_tool("list_assets")
	assert_false(t.requires_edit_mode, "list_assets must be safe in play mode")
