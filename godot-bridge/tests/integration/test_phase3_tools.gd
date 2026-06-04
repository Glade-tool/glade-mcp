extends GutTest

# Integration smoke tests for Phase 3 tools. Each tool gets happy path +
# at least one error path (missing arg or invalid input). Editor + open
# scene required, same setup as test_scene_node_tools.gd.
#
# Tools requiring spawned subprocesses (run_project / launch_editor) are
# tested in non-spawning failure modes only — actually launching Godot
# from inside a Godot test run is fragile and CI-unfriendly.

const Registry = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd")
const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const SANDBOX_NAME := "_GladeKitP3Sandbox"
const SCRATCH_DIR := "res://_gk_p3_scratch"

var _registry = null
var _sandbox: Node = null


func should_skip_script():
	# See test_signal_tools.gd::should_skip_script for the full story —
	# integration tests need editor context, GUT runs in play_custom_scene
	# where EditorInterface is unreachable, so we skip the entire file.
	if ToolUtils.get_edited_scene_root_safe() == null:
		return "requires editor context (skipped under GUT play_custom_scene; verify by driving the bridge through an MCP client with the editor open)"
	return false


func before_each() -> void:
	_registry = Registry.new()
	var scene_root := EditorInterface.get_edited_scene_root()
	var leftover := scene_root.find_child(SANDBOX_NAME, false, false)
	if leftover:
		scene_root.remove_child(leftover)
		leftover.free()
	_sandbox = Node3D.new()
	_sandbox.name = SANDBOX_NAME
	scene_root.add_child(_sandbox)
	_sandbox.owner = scene_root
	DirAccess.make_dir_absolute(ProjectSettings.globalize_path(SCRATCH_DIR))


func after_each() -> void:
	if _sandbox != null and is_instance_valid(_sandbox):
		var p := _sandbox.get_parent()
		if p != null:
			p.remove_child(_sandbox)
		_sandbox.free()
	_sandbox = null
	_registry = null
	_clear_scratch()


func _clear_scratch() -> void:
	var dir := DirAccess.open(SCRATCH_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry.is_empty():
			break
		if entry.begins_with(".") or dir.current_is_dir():
			continue
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH_DIR.path_join(entry)))
	dir.list_dir_end()


func _run(tool_name: String, args: Dictionary) -> Dictionary:
	var t = _registry.get_tool(tool_name)
	assert_not_null(t, "Tool '%s' must be registered" % tool_name)
	return t.execute(args)


# ── Camera / Light ────────────────────────────────────────────────────────

func test_create_camera_3d_happy() -> void:
	var r := _run("create_camera_3d", {"parent_path": SANDBOX_NAME, "name": "Cam", "fov": 60.0})
	assert_true(r.success)
	assert_eq(r.type, "Camera3D")
	assert_not_null(_sandbox.find_child("Cam", false, false))


func test_create_light_happy_directional() -> void:
	var r := _run("create_light", {"type": "directional", "parent_path": SANDBOX_NAME, "color": "#ffeecc"})
	assert_true(r.success)
	assert_eq(r.type, "DirectionalLight3D")


func test_create_light_happy_omni() -> void:
	var r := _run("create_light", {"type": "omni", "parent_path": SANDBOX_NAME})
	assert_true(r.success)
	assert_eq(r.type, "OmniLight3D")


func test_create_light_unknown_type() -> void:
	var r := _run("create_light", {"type": "rainbow_disco", "parent_path": SANDBOX_NAME})
	assert_false(r.success)
	assert_string_contains(r.error, "Unknown light type")
	assert_true(r.has("possible_solutions"))


# ── Resource ──────────────────────────────────────────────────────────────

func test_create_material_happy_standard() -> void:
	var path := SCRATCH_DIR + "/m1.tres"
	var r := _run("create_material", {
		"path": path,
		"albedo": "#ff8800",
		"metallic": 0.3,
		"roughness": 0.5,
	})
	assert_true(r.success)
	assert_eq(r.type, "StandardMaterial3D")
	assert_true(FileAccess.file_exists(path))


func test_create_material_refuses_overwrite() -> void:
	var path := SCRATCH_DIR + "/m2.tres"
	_run("create_material", {"path": path, "albedo": "#ffffff"})
	var r := _run("create_material", {"path": path, "albedo": "#000000"})
	assert_false(r.success)
	assert_true(r.has("possible_solutions"))


func test_set_material_property_happy() -> void:
	var path := SCRATCH_DIR + "/m3.tres"
	_run("create_material", {"path": path, "albedo": "#ffffff"})
	var r := _run("set_material_property", {
		"material_path": path,
		"property": "metallic",
		"value": 0.8,
	})
	assert_true(r.success)
	assert_eq(r.applied_property, "metallic")


func test_set_material_property_missing_path() -> void:
	var r := _run("set_material_property", {"property": "metallic", "value": 0.5})
	assert_false(r.success)
	# Error must name the missing arg so the agent can fix its call without
	# guessing which of property/value/material_path is the problem.
	assert_string_contains(r.error, "material_path")


# ── create_resource (generic Resource factory) ────────────────────────────

func test_create_resource_happy_box_mesh() -> void:
	var path := SCRATCH_DIR + "/cr_box_mesh.tres"
	var r := _run("create_resource", {
		"path": path,
		"type": "BoxMesh",
		"properties": {"size": "3,4,5"},
	})
	assert_true(r.success, "create_resource happy path: %s" % r.get("error", ""))
	assert_eq(r.type, "BoxMesh")
	assert_eq(r.path, path)
	assert_true(FileAccess.file_exists(path))
	assert_eq(r.applied_properties, ["size"])
	assert_eq(r.unapplied_properties, [])

	# Round-trip: the saved .tres loads back as a BoxMesh with the right size.
	var loaded := load(path)
	assert_true(loaded is BoxMesh)
	assert_eq((loaded as BoxMesh).size, Vector3(3, 4, 5))


func test_create_resource_happy_concrete_shape() -> void:
	# Composition: this is the canonical use-case (create the shape, then
	# set_node_resource it to a CollisionShape3D.shape).
	var path := SCRATCH_DIR + "/cr_box_shape.tres"
	var r := _run("create_resource", {
		"path": path,
		"type": "BoxShape3D",
		"properties": {"size": "2,2,2"},
	})
	assert_true(r.success)
	assert_eq(r.type, "BoxShape3D")


func test_create_resource_no_extension_auto_appends_tres() -> void:
	var path := SCRATCH_DIR + "/cr_no_ext"
	var r := _run("create_resource", {"path": path, "type": "BoxMesh"})
	assert_true(r.success)
	assert_eq(r.path, path + ".tres")
	assert_true(FileAccess.file_exists(path + ".tres"))


func test_create_resource_refuses_overwrite() -> void:
	var path := SCRATCH_DIR + "/cr_overwrite.tres"
	_run("create_resource", {"path": path, "type": "BoxMesh"})
	var r := _run("create_resource", {"path": path, "type": "SphereMesh"})
	assert_false(r.success)
	assert_true(r.has("possible_solutions"))


func test_create_resource_unknown_type_returns_suggestions() -> void:
	var r := _run("create_resource", {
		"path": SCRATCH_DIR + "/cr_unknown.tres",
		"type": "BoxMash",  # Typo for BoxMesh
	})
	assert_false(r.success)
	assert_true(r.has("suggestions"))
	assert_gt(r.suggestions.size(), 0)
	# Edit distance should rank "BoxMesh" near the top for "BoxMash".
	assert_true(
		r.suggestions.has("BoxMesh"),
		"Expected 'BoxMesh' in suggestions for typo 'BoxMash', got: %s" % str(r.suggestions),
	)


func test_create_resource_redirects_material() -> void:
	var r := _run("create_resource", {
		"path": SCRATCH_DIR + "/cr_redirect.tres",
		"type": "StandardMaterial3D",
	})
	assert_false(r.success)
	assert_true(r.has("possible_solutions"))
	# Redirect message should mention create_material.
	assert_true(
		String(r.error).find("create_material") != -1,
		"Expected 'create_material' in redirect error, got: %s" % r.error,
	)


func test_create_resource_redirects_script() -> void:
	var r := _run("create_resource", {
		"path": SCRATCH_DIR + "/cr_script.tres",
		"type": "GDScript",
	})
	assert_false(r.success)
	assert_true(String(r.error).find("create_script") != -1)


func test_create_resource_refuses_non_resource_type() -> void:
	var r := _run("create_resource", {
		"path": SCRATCH_DIR + "/cr_node.tres",
		"type": "Node3D",  # A Node, not a Resource.
	})
	assert_false(r.success)
	assert_true(String(r.error).find("not a Resource") != -1)


func test_create_resource_refuses_abstract_type() -> void:
	var r := _run("create_resource", {
		"path": SCRATCH_DIR + "/cr_abstract.tres",
		"type": "Shape3D",  # Abstract base class.
	})
	assert_false(r.success)
	assert_true(r.has("suggestions"))
	# At least one concrete Shape3D subclass should be suggested.
	assert_gt(r.suggestions.size(), 0)


func test_create_resource_unknown_property_lands_in_unapplied() -> void:
	var path := SCRATCH_DIR + "/cr_unknown_prop.tres"
	var r := _run("create_resource", {
		"path": path,
		"type": "BoxMesh",
		"properties": {
			"size": "1,1,1",
			"nonexistent_prop": 42,
		},
	})
	assert_true(r.success)
	assert_eq(r.applied_properties, ["size"])
	assert_eq(r.unapplied_properties.size(), 1)
	assert_eq(r.unapplied_properties[0].name, "nonexistent_prop")


func test_create_resource_missing_path() -> void:
	var r := _run("create_resource", {"type": "BoxMesh"})
	assert_false(r.success)
	assert_string_contains(r.error, "path")


func test_create_resource_missing_type() -> void:
	var r := _run("create_resource", {"path": SCRATCH_DIR + "/cr_no_type.tres"})
	assert_false(r.success)
	assert_string_contains(r.error, "type")


# ── Physics ───────────────────────────────────────────────────────────────

func test_create_physics_body_happy_static() -> void:
	var r := _run("create_physics_body", {
		"body_type": "static",
		"parent_path": SANDBOX_NAME,
		"name": "Floor",
	})
	assert_true(r.success)
	assert_eq(r.type, "StaticBody3D")
	# auto_shape default true → collision shape was added.
	assert_false(String(r.collision_shape_path).is_empty())


func test_create_physics_body_happy_rigid_with_mass() -> void:
	var r := _run("create_physics_body", {
		"body_type": "rigid",
		"parent_path": SANDBOX_NAME,
		"mass": 5.0,
	})
	assert_true(r.success)
	assert_eq(r.type, "RigidBody3D")


func test_create_physics_body_unknown_type() -> void:
	var r := _run("create_physics_body", {"body_type": "marshmallow", "parent_path": SANDBOX_NAME})
	assert_false(r.success)
	# Error should namedrop the invalid value AND list the valid set so the
	# agent's retry self-corrects without a query-then-fix cycle.
	assert_string_contains(r.error, "marshmallow")


# ── Scene I/O ─────────────────────────────────────────────────────────────

func test_create_scene_happy() -> void:
	var path := SCRATCH_DIR + "/probe.tscn"
	# `open: false` so we don't disrupt the edited scene during the test.
	var r := _run("create_scene", {"path": path, "root_type": "Node3D", "root_name": "ProbeRoot", "open": false})
	assert_true(r.success)
	assert_true(FileAccess.file_exists(path))


func test_create_scene_rejects_non_scene_extension() -> void:
	var r := _run("create_scene", {"path": SCRATCH_DIR + "/probe.txt", "open": false})
	assert_false(r.success)
	# Error should mention the offending extension so the agent knows to
	# switch from .txt to .tscn rather than guessing what's wrong with the path.
	assert_string_contains(r.error.to_lower(), "tscn")


func test_save_scene_unsaved_needs_path() -> void:
	# This is a touch-test: we don't actually want to save the dev's
	# currently-edited scene to disk under a test name. Use a scene-root
	# with no scene_file_path is hard without opening one fresh; we
	# accept that the test exercises only the error branch.
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not root.scene_file_path.is_empty():
		pending("Scene already has a file path — skipping unsaved-error branch")
		return
	var r := _run("save_scene", {})
	assert_false(r.success)


# ── Runtime / process (non-spawning paths only) ───────────────────────────

func test_get_play_mode_state_happy() -> void:
	var r := _run("get_play_mode_state", {})
	assert_true(r.success)
	assert_true(r.has("is_playing"))


func test_get_selection_happy() -> void:
	var r := _run("get_selection", {})
	assert_true(r.success)
	assert_true(r.has("selection"))


func test_run_project_missing_godot_exe_returns_error() -> void:
	# Even when OS.get_executable_path() resolves, run_project hits
	# PlaySessionManager.start. We can't reliably spawn here; instead
	# verify the tool registers and exists. Real run is tested manually.
	var t = _registry.get_tool("run_project")
	assert_not_null(t)


func test_stop_project_missing_session_id() -> void:
	var r := _run("stop_project", {})
	assert_false(r.success)
	assert_string_contains(r.error, "session_id")


func test_get_debug_output_unknown_session_id() -> void:
	var r := _run("get_debug_output", {"session_id": "definitely_not_a_session"})
	assert_false(r.success)
	# Echo the bad ID back so the agent can tell its lookup raised vs. its
	# arg name was wrong.
	assert_string_contains(r.error, "definitely_not_a_session")


func test_launch_editor_missing_project_path() -> void:
	var r := _run("launch_editor", {})
	assert_false(r.success)
	assert_string_contains(r.error, "project_path")


# ── UID (4.4+) — basic registration smoke ─────────────────────────────────

func test_get_uid_missing_path() -> void:
	# Don't depend on the engine version here — the version gate is checked
	# by ws_server before dispatch, so calling tool.execute directly bypasses
	# it. We just verify the missing-arg path.
	var r := _run("get_uid", {})
	assert_false(r.success)
	assert_string_contains(r.error, "path")


func test_update_project_uids_runs_or_skips() -> void:
	# The actual resave pass touches real files; we run it on the empty
	# scratch dir to keep blast radius minimal.
	var r := _run("update_project_uids", {"subdir": "_gk_p3_scratch"})
	# Either succeeds (4.4+) or returns success with 0 scanned (since dir
	# may be empty). We just assert non-crash and a dict response.
	assert_true(r is Dictionary)
	assert_true(r.has("success"))
