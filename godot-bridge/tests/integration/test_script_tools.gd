extends GutTest

# Integration tests for the 5 Script tools. Uses res://_gk_test_scratch/ as
# a sandbox directory; cleared before and after every test.

const Registry = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")
const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const SANDBOX_DIR := "res://_gk_test_scratch"

var _registry = null


func should_skip_script():
	# Script tools call EditorInterface.get_resource_filesystem() to register
	# newly-created scripts with the editor — unreachable under GUT's
	# play_custom_scene runner. See test_signal_tools.gd::should_skip_script.
	if ToolUtils.get_edited_scene_root_safe() == null:
		return "requires editor context (skipped under GUT play_custom_scene; verify by driving the bridge through an MCP client with the editor open)"
	return false


func before_each() -> void:
	_registry = Registry.new()
	_clear_sandbox()
	# Reset session-created tracker so each test starts clean.
	SessionTracker.clear()
	DirAccess.make_dir_absolute(ProjectSettings.globalize_path(SANDBOX_DIR))


func after_each() -> void:
	_clear_sandbox()
	SessionTracker.clear()
	_registry = null


func _clear_sandbox() -> void:
	var dir := DirAccess.open(SANDBOX_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry.is_empty():
			break
		if entry.begins_with("."):
			continue
		var path: String = SANDBOX_DIR.path_join(entry)
		if dir.current_is_dir():
			# Best effort — leave nested dirs alone, no test creates them.
			continue
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	dir.list_dir_end()


func _run(tool_name: String, args: Dictionary) -> Dictionary:
	var t = _registry.get_tool(tool_name)
	assert_not_null(t, "Tool '%s' must be registered" % tool_name)
	return t.execute(args)


# ── create_script ─────────────────────────────────────────────────────────

func test_create_script_happy() -> void:
	var path := SANDBOX_DIR + "/hello.gd"
	var r := _run("create_script", {
		"script_path": path,
		"content": "extends Node\nfunc _ready():\n\tprint(\"hi\")\n",
	})
	assert_true(r.success)
	assert_eq(r.script_path, path)
	assert_true(FileAccess.file_exists(path))


func test_create_script_auto_appends_extension() -> void:
	var path := SANDBOX_DIR + "/no_ext"
	var r := _run("create_script", {
		"script_path": path,
		"content": "extends Node",
	})
	assert_true(r.success)
	assert_true(FileAccess.file_exists(path + ".gd"))


func test_create_script_missing_path() -> void:
	var r := _run("create_script", {"content": "extends Node"})
	assert_false(r.success)


func test_create_script_missing_content() -> void:
	var r := _run("create_script", {"script_path": SANDBOX_DIR + "/x.gd"})
	assert_false(r.success)


func test_create_script_refuses_overwrite() -> void:
	var path := SANDBOX_DIR + "/twice.gd"
	var first := _run("create_script", {"script_path": path, "content": "extends Node"})
	assert_true(first.success)
	var second := _run("create_script", {"script_path": path, "content": "extends Node2D"})
	assert_false(second.success)
	assert_string_contains(second.error, "already exists")


func test_create_script_rejects_non_gd_extension() -> void:
	var r := _run("create_script", {
		"script_path": SANDBOX_DIR + "/bad.cs",
		"content": "// hi",
	})
	assert_false(r.success)


# ── modify_script ─────────────────────────────────────────────────────────

func test_modify_script_happy_after_create() -> void:
	var path := SANDBOX_DIR + "/m.gd"
	_run("create_script", {"script_path": path, "content": "extends Node"})
	var r := _run("modify_script", {
		"script_path": path,
		"content": "extends Node2D",
	})
	assert_true(r.success)
	var fa := FileAccess.open(path, FileAccess.READ)
	assert_not_null(fa)
	assert_eq(fa.get_as_text(), "extends Node2D")
	fa.close()


func test_modify_script_refuses_preexisting_without_confirm() -> void:
	# Write a file outside the session tracker — simulates a user-authored script.
	var path := SANDBOX_DIR + "/user_authored.gd"
	var fa := FileAccess.open(path, FileAccess.WRITE)
	fa.store_string("extends Node")
	fa.close()
	var r := _run("modify_script", {
		"script_path": path,
		"content": "OVERWRITTEN",
	})
	assert_false(r.success)
	assert_string_contains(r.error, "confirm_existing_file_modification")
	# File contents must not have been touched.
	var check := FileAccess.open(path, FileAccess.READ)
	assert_eq(check.get_as_text(), "extends Node")
	check.close()


func test_modify_script_allows_preexisting_with_confirm() -> void:
	var path := SANDBOX_DIR + "/user_authored.gd"
	var fa := FileAccess.open(path, FileAccess.WRITE)
	fa.store_string("extends Node")
	fa.close()
	var r := _run("modify_script", {
		"script_path": path,
		"content": "extends Node2D",
		"confirm_existing_file_modification": true,
	})
	assert_true(r.success)


func test_modify_script_missing_path() -> void:
	var r := _run("modify_script", {"content": "extends Node"})
	assert_false(r.success)


func test_modify_script_nonexistent_file() -> void:
	var r := _run("modify_script", {
		"script_path": SANDBOX_DIR + "/nope.gd",
		"content": "extends Node",
		"confirm_existing_file_modification": true,
	})
	assert_false(r.success)
	assert_string_contains(r.error, "does not exist")


# ── get_script_content ────────────────────────────────────────────────────

func test_get_script_content_happy() -> void:
	var path := SANDBOX_DIR + "/read.gd"
	_run("create_script", {"script_path": path, "content": "extends Node\n# hello\n"})
	var r := _run("get_script_content", {"script_path": path})
	assert_true(r.success)
	assert_string_contains(r.content, "hello")


func test_get_script_content_missing_arg() -> void:
	var r := _run("get_script_content", {})
	assert_false(r.success)


func test_get_script_content_nonexistent() -> void:
	var r := _run("get_script_content", {"script_path": SANDBOX_DIR + "/none.gd"})
	assert_false(r.success)


# ── find_scripts ──────────────────────────────────────────────────────────

func test_find_scripts_happy() -> void:
	_run("create_script", {"script_path": SANDBOX_DIR + "/uniquename_one.gd", "content": "extends Node"})
	_run("create_script", {"script_path": SANDBOX_DIR + "/uniquename_two.gd", "content": "extends Node"})
	var r := _run("find_scripts", {"name_contains": "uniquename"})
	assert_true(r.success)
	assert_gte(r.count, 2)


func test_find_scripts_no_filter_returns_all() -> void:
	# With include_addons=false, base project still has our sandbox files.
	_run("create_script", {"script_path": SANDBOX_DIR + "/probe.gd", "content": "extends Node"})
	var r := _run("find_scripts", {"max_results": 5})
	assert_true(r.success)


func test_find_scripts_wrong_type_max_results_clamped() -> void:
	var r := _run("find_scripts", {"max_results": "huh"})
	assert_true(r.success)


# ── attach_script_to_node ─────────────────────────────────────────────────

const SANDBOX_NODE_NAME := "_GladeKitTestScriptNode"


func _ensure_sandbox_node() -> Node:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	var existing := scene_root.find_child(SANDBOX_NODE_NAME, false, false)
	if existing != null:
		scene_root.remove_child(existing)
		existing.free()
	var n := Node3D.new()
	n.name = SANDBOX_NODE_NAME
	scene_root.add_child(n)
	n.owner = scene_root
	return n


func _teardown_sandbox_node() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var n := scene_root.find_child(SANDBOX_NODE_NAME, false, false)
	if n != null:
		scene_root.remove_child(n)
		n.free()


func test_attach_script_to_node_happy() -> void:
	var n := _ensure_sandbox_node()
	if n == null:
		pending("No edited scene open")
		return
	var script_path := SANDBOX_DIR + "/attach.gd"
	_run("create_script", {"script_path": script_path, "content": "extends Node3D"})
	var r := _run("attach_script_to_node", {
		"node_path": SANDBOX_NODE_NAME,
		"script_path": script_path,
	})
	assert_true(r.success)
	assert_not_null(n.get_script())
	_teardown_sandbox_node()


func test_attach_script_to_node_missing_node_path() -> void:
	var r := _run("attach_script_to_node", {"script_path": SANDBOX_DIR + "/x.gd"})
	assert_false(r.success)


func test_attach_script_to_node_nonexistent_script() -> void:
	var n := _ensure_sandbox_node()
	if n == null:
		pending("No edited scene open")
		return
	var r := _run("attach_script_to_node", {
		"node_path": SANDBOX_NODE_NAME,
		"script_path": SANDBOX_DIR + "/does_not_exist.gd",
	})
	assert_false(r.success)
	_teardown_sandbox_node()
