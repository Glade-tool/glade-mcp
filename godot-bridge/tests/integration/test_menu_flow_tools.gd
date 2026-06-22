extends GutTest

# Integration tests for the menu / scene-flow family (v0.7.x):
#   create_main_menu  — writes a standalone title-screen .tscn + vetted script.
#   create_pause_menu — drops an Esc-toggled pause overlay onto the open scene.
#
# Both need editor context (EditorInterface), so the script self-skips under
# GUT's play_custom_scene runner (same pattern as the other integration suites).
#
# Isolation: everything the tools write goes under a throwaway res:// test dir
# (so the generated scripts don't land in the real res://scripts), and the
# pause-menu node — which the tool parents under the edited scene root — is
# removed in after_each so we never pollute the dogfood scene. We pass
# open=false to create_main_menu so it doesn't swap the editor's edited scene
# out from under the next test.

const Registry = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd")
const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const TEST_DIR := "res://_gladekit_menu_test"
const MENU_SCENE := "res://_gladekit_menu_test/main_menu.tscn"
const MENU_SCENE_2 := "res://_gladekit_menu_test/main_menu_2.tscn"
const PAUSE_NODE := "PauseMenu"

var _registry = null


func should_skip_script():
	if ToolUtils.get_edited_scene_root_safe() == null:
		return "requires editor context (skipped under GUT play_custom_scene; verify by driving the bridge through an MCP client with the editor open)"
	return false


func before_each() -> void:
	_registry = Registry.new()
	_cleanup()


func after_each() -> void:
	_cleanup()
	_registry = null


func _run(tool_name: String, args: Dictionary) -> Dictionary:
	var t = _registry.get_tool(tool_name)
	assert_not_null(t, "Tool '%s' must be registered" % tool_name)
	return t.execute(args)


# Remove any pause overlay the tool parented under the edited scene root, then
# wipe the throwaway test directory + its .import sidecars.
func _cleanup() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		var leftover := root.find_child(PAUSE_NODE, false, false)
		if leftover:
			root.remove_child(leftover)
			leftover.free()
	_rm_dir(TEST_DIR)


func _rm_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# ── create_main_menu ──────────────────────────────────────────────────────

func test_create_main_menu_writes_scene_and_script() -> void:
	var r := _run("create_main_menu", {
		"path": MENU_SCENE,
		"directory": TEST_DIR,
		"title": "Test Game",
		"play_target": "res://scenes/level1.tscn",
		"open": false,
	})
	assert_true(r.success, "create_main_menu should succeed: %s" % r.get("message", ""))
	assert_eq(r.path, MENU_SCENE)
	assert_eq(r.play_target, "res://scenes/level1.tscn")
	assert_false(bool(r.is_main_scene), "set_as_main_scene defaults false — project.godot untouched")
	assert_true(FileAccess.file_exists(MENU_SCENE), "menu scene file should exist on disk")
	assert_true(FileAccess.file_exists(r.created_script), "menu script should exist on disk")


func test_create_main_menu_tree_has_title_and_buttons() -> void:
	var r := _run("create_main_menu", {
		"path": MENU_SCENE,
		"directory": TEST_DIR,
		"title": "Hello",
		"include_quit": true,
		"open": false,
	})
	assert_true(r.success)
	# Load + instantiate the saved scene and inspect its tree.
	var packed = load(MENU_SCENE)
	assert_true(packed is PackedScene, "saved menu must load as a PackedScene")
	var inst = packed.instantiate()
	var title := inst.find_child("TitleLabel", true, false)
	assert_not_null(title, "menu should contain a TitleLabel")
	assert_eq((title as Label).text, "Hello", "title text should be applied")
	assert_not_null(inst.find_child("PlayButton", true, false), "menu should contain a PlayButton")
	assert_not_null(inst.find_child("QuitButton", true, false), "include_quit=true should add a QuitButton")
	inst.free()


func test_create_main_menu_omits_quit_when_disabled() -> void:
	var r := _run("create_main_menu", {
		"path": MENU_SCENE,
		"directory": TEST_DIR,
		"include_quit": false,
		"open": false,
	})
	assert_true(r.success)
	var inst = (load(MENU_SCENE) as PackedScene).instantiate()
	assert_null(inst.find_child("QuitButton", true, false), "include_quit=false should omit the QuitButton")
	inst.free()


func test_create_main_menu_refuses_overwrite() -> void:
	var first := _run("create_main_menu", {"path": MENU_SCENE, "directory": TEST_DIR, "open": false})
	assert_true(first.success)
	var second := _run("create_main_menu", {"path": MENU_SCENE, "directory": TEST_DIR, "open": false})
	assert_false(second.success, "second call must refuse without overwrite=true")
	assert_true(second.has("possible_solutions"), "error should hand the agent a recovery path")


func test_create_main_menu_reuses_script_for_a_new_scene() -> void:
	# Composition regression: building a SECOND menu scene (a different path)
	# must reuse the shared vetted main_menu.gd, not refuse because the script
	# already exists. The scene path is still guarded against clobbering
	# (test_create_main_menu_refuses_overwrite covers that); only the shared
	# script is reused. Pre-fix this hard-refused, leaving the second menu unbuilt.
	var first := _run("create_main_menu", {"path": MENU_SCENE, "directory": TEST_DIR, "open": false})
	assert_true(first.success, "first menu should build")
	assert_true(FileAccess.file_exists(first.created_script), "shared menu script should exist after the first call")
	var second := _run("create_main_menu", {"path": MENU_SCENE_2, "directory": TEST_DIR, "open": false})
	assert_true(second.success, "second menu at a NEW path must reuse the existing script, not refuse: %s" % second.get("message", ""))
	assert_true(FileAccess.file_exists(MENU_SCENE_2), "second menu scene should be written to disk")


# ── create_pause_menu ─────────────────────────────────────────────────────

func test_create_pause_menu_adds_always_running_overlay() -> void:
	var r := _run("create_pause_menu", {
		"directory": TEST_DIR,
		"menu_target": MENU_SCENE,
	})
	assert_true(r.success, "create_pause_menu should succeed: %s" % r.get("message", ""))
	assert_eq(r.group, "pause_menu")
	assert_eq(r.menu_target, MENU_SCENE)

	var root := EditorInterface.get_edited_scene_root()
	var layer := root.find_child(PAUSE_NODE, false, false)
	assert_not_null(layer, "PauseMenu node should be parented under the scene root")
	assert_true(layer is CanvasLayer, "pause overlay should be a CanvasLayer")
	assert_eq(layer.process_mode, Node.PROCESS_MODE_ALWAYS, "overlay must keep running while the tree is paused")
	assert_true(layer.is_in_group("pause_menu"), "overlay should join the pause_menu group")

	var panel := layer.find_child("Panel", true, false)
	assert_not_null(panel, "overlay should contain a Panel")
	assert_false((panel as Control).visible, "panel should start hidden (shown only while paused)")
	assert_not_null(layer.find_child("ResumeButton", true, false), "overlay should contain a Resume button")
	assert_not_null(layer.find_child("QuitButton", true, false), "overlay should contain a Quit button")


func test_create_pause_menu_refuses_second_overlay() -> void:
	var first := _run("create_pause_menu", {"directory": TEST_DIR})
	assert_true(first.success)
	var second := _run("create_pause_menu", {"directory": TEST_DIR})
	assert_false(second.success, "a scene may hold only one pause overlay")
	assert_true(second.has("possible_solutions"), "error should hand the agent a recovery path")


func test_create_pause_menu_reuses_existing_script() -> void:
	# Composition regression: once the shared pause_menu.gd exists (a prior game),
	# adding a pause overlay to a DIFFERENT scene that has none must reuse the
	# script and still build the overlay — not refuse. The per-scene group guard
	# (test_create_pause_menu_refuses_second_overlay) is what prevents duplicates;
	# an existing script file is not a reason to abort. Pre-fix this hard-refused,
	# so a second game built in a fresh scene silently got no pause menu.
	var first := _run("create_pause_menu", {"directory": TEST_DIR})
	assert_true(first.success, "first overlay should build + write the shared script")
	var script_path: String = first.get("created_script", TEST_DIR + "/pause_menu.gd")
	assert_true(FileAccess.file_exists(script_path), "shared pause script should exist after the first call")
	# Remove the overlay so the one-per-scene group guard doesn't mask the script
	# path we're actually exercising (simulates a fresh scene with no overlay).
	var root := EditorInterface.get_edited_scene_root()
	var overlay := root.find_child(PAUSE_NODE, false, false)
	if overlay:
		root.remove_child(overlay)
		overlay.free()
	var second := _run("create_pause_menu", {"directory": TEST_DIR})
	assert_true(second.success, "with the script present but no overlay in scene, the tool must reuse the script and rebuild the overlay: %s" % second.get("message", ""))
	assert_not_null(EditorInterface.get_edited_scene_root().find_child(PAUSE_NODE, false, false), "overlay should be rebuilt on the reuse path")
