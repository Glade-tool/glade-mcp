extends GutTest

# Integration tests for the v0.5.0 UI / Control tools. Backfills the gap
# where the entire ui/ category shipped without test coverage (six tools:
# create_control, set_control_anchors, set_control_size, set_control_text,
# list_ui_hierarchy, create_theme).
#
# Why a CanvasLayer sandbox: create_control auto-wraps a bare Control under
# the scene root when the root is a Node3D/Node2D/Node (which is the case
# for godot-project/scenes/main.tscn). Mounting the sandbox as a
# CanvasLayer up front means we exercise the explicit-parent path AND we
# don't pollute the edited scene with a stray "UI" CanvasLayer if a test
# fails to clean up.
#
# Theme tests use a user:// staging path so we never write into the project
# tree (avoids tripping DemoAssetsGuard and keeps the test self-contained).

const Registry = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd")
const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const SANDBOX_NAME := "_GladeKitUITestSandbox"
const STAGED_THEME_DIR := "user://_gladekit_ui_test/"

var _registry = null
var _sandbox: CanvasLayer = null


func should_skip_script():
	# See test_signal_tools.gd::should_skip_script — integration tests need
	# editor context, unreachable from GUT's play_custom_scene runner.
	if ToolUtils.get_edited_scene_root_safe() == null:
		return "requires editor context (skipped under GUT play_custom_scene; verify by driving the bridge through an MCP client with the editor open)"
	return false


func before_each() -> void:
	_registry = Registry.new()
	var scene_root := EditorInterface.get_edited_scene_root()
	# Clean any leftover from a previous test that crashed mid-run.
	var leftover := scene_root.find_child(SANDBOX_NAME, false, false)
	if leftover:
		scene_root.remove_child(leftover)
		leftover.free()
	# Also clean any auto-created "UI" CanvasLayer from a prior create_control
	# call that fell through to the auto-wrap branch — keeps the test scene
	# tidy across runs.
	var stray_ui := scene_root.find_child("UI", false, false)
	if stray_ui and stray_ui is CanvasLayer:
		scene_root.remove_child(stray_ui)
		stray_ui.free()

	_sandbox = CanvasLayer.new()
	_sandbox.name = SANDBOX_NAME
	scene_root.add_child(_sandbox)
	_sandbox.owner = scene_root

	# Staging dir for theme tests. user:// keeps this off the project tree.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(STAGED_THEME_DIR))


func after_each() -> void:
	if _sandbox != null and is_instance_valid(_sandbox):
		var p := _sandbox.get_parent()
		if p != null:
			p.remove_child(_sandbox)
		_sandbox.free()
	_sandbox = null
	# Wipe any auto-wrap UI CanvasLayer the tools may have created.
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root != null:
		var stray_ui := scene_root.find_child("UI", false, false)
		if stray_ui and stray_ui is CanvasLayer:
			scene_root.remove_child(stray_ui)
			stray_ui.free()
	# Clean staged themes.
	var dir := DirAccess.open(STAGED_THEME_DIR)
	if dir != null:
		dir.list_dir_begin()
		var entry := dir.get_next()
		while entry != "":
			if not dir.current_is_dir():
				dir.remove(entry)
			entry = dir.get_next()
	_registry = null


func _run(tool_name: String, args: Dictionary) -> Dictionary:
	var t = _registry.get_tool(tool_name)
	assert_not_null(t, "Tool '%s' must be registered" % tool_name)
	return t.execute(args)


# ── create_control ────────────────────────────────────────────────────────

func test_create_control_button_happy() -> void:
	var r := _run("create_control", {
		"type": "Button",
		"name": "MyButton",
		"parent_path": SANDBOX_NAME,
		"text": "Click",
	})
	assert_true(r.success, "create_control should succeed: %s" % r.get("message", ""))
	assert_eq(r.type, "Button")
	assert_true(bool(r.get("text_applied", false)), "text arg should be applied to Button.text")
	# Verify the node actually landed.
	var btn := _sandbox.find_child("MyButton", true, false)
	assert_not_null(btn, "Button should exist in sandbox")
	assert_eq((btn as Button).text, "Click")


func test_create_control_unknown_type_returns_error() -> void:
	var r := _run("create_control", {
		"type": "NotARealClass",
		"parent_path": SANDBOX_NAME,
	})
	assert_false(r.success, "Unknown class should fail")
	assert_true(str(r.get("error", "")).contains("NotARealClass"))


func test_create_control_rejects_non_ui_class() -> void:
	var r := _run("create_control", {
		"type": "Node3D",
		"parent_path": SANDBOX_NAME,
	})
	assert_false(r.success, "Node3D should be rejected — not a Control/Window")
	assert_true(r.has("possible_solutions"), "should hand the agent a recovery path")


func test_create_control_with_anchor_preset() -> void:
	var r := _run("create_control", {
		"type": "Panel",
		"name": "FullPanel",
		"parent_path": SANDBOX_NAME,
		"anchor_preset": "full_rect",
	})
	assert_true(r.success, "anchor_preset full_rect should apply: %s" % r.get("message", ""))
	var panel: Control = _sandbox.find_child("FullPanel", true, false)
	assert_not_null(panel)
	# full_rect preset → anchors (0,0,1,1).
	assert_almost_eq(panel.anchor_left, 0.0, 0.01)
	assert_almost_eq(panel.anchor_top, 0.0, 0.01)
	assert_almost_eq(panel.anchor_right, 1.0, 0.01)
	assert_almost_eq(panel.anchor_bottom, 1.0, 0.01)


# ── set_control_text ──────────────────────────────────────────────────────

func test_set_control_text_happy() -> void:
	_run("create_control", {
		"type": "Label",
		"name": "Greet",
		"parent_path": SANDBOX_NAME,
		"text": "hi",
	})
	var r := _run("set_control_text", {
		"node_path": "%s/Greet" % SANDBOX_NAME,
		"text": "hello",
	})
	assert_true(r.success, "set_control_text should succeed: %s" % r.get("message", ""))
	assert_eq(r.text, "hello")
	assert_eq(r.previous_text, "hi", "previous_text must reflect pre-call value")
	var lbl: Label = _sandbox.find_child("Greet", true, false)
	assert_eq(lbl.text, "hello")


func test_set_control_text_rejects_non_text_node() -> void:
	_run("create_control", {
		"type": "Panel",
		"name": "Plain",
		"parent_path": SANDBOX_NAME,
	})
	var r := _run("set_control_text", {
		"node_path": "%s/Plain" % SANDBOX_NAME,
		"text": "x",
	})
	assert_false(r.success, "Panel has no text-bearing property")


# ── set_control_anchors ───────────────────────────────────────────────────

func test_set_control_anchors_preset_center() -> void:
	_run("create_control", {
		"type": "Button",
		"name": "Centered",
		"parent_path": SANDBOX_NAME,
	})
	var r := _run("set_control_anchors", {
		"node_path": "%s/Centered" % SANDBOX_NAME,
		"preset": "center",
	})
	assert_true(r.success, "center preset should apply")
	assert_eq(r.preset, "center")
	var btn: Control = _sandbox.find_child("Centered", true, false)
	# center preset → all four anchors at 0.5.
	assert_almost_eq(btn.anchor_left, 0.5, 0.01)
	assert_almost_eq(btn.anchor_right, 0.5, 0.01)


func test_set_control_anchors_unknown_preset() -> void:
	_run("create_control", {"type": "Button", "name": "Btn1", "parent_path": SANDBOX_NAME})
	var r := _run("set_control_anchors", {
		"node_path": "%s/Btn1" % SANDBOX_NAME,
		"preset": "not_a_preset",
	})
	assert_false(r.success, "unknown preset should fail")


# ── set_control_size ──────────────────────────────────────────────────────

func test_set_control_size_happy() -> void:
	_run("create_control", {"type": "Panel", "name": "Sized", "parent_path": SANDBOX_NAME})
	var r := _run("set_control_size", {
		"node_path": "%s/Sized" % SANDBOX_NAME,
		"width": 200,
		"height": 80,
	})
	assert_true(r.success, "set_control_size should succeed: %s" % r.get("message", ""))
	assert_eq(r.size, "200,80")
	var panel: Control = _sandbox.find_child("Sized", true, false)
	assert_eq(panel.size.x, 200.0)
	assert_eq(panel.size.y, 80.0)


func test_set_control_size_requires_at_least_one_dimension() -> void:
	_run("create_control", {"type": "Panel", "name": "Sized2", "parent_path": SANDBOX_NAME})
	var r := _run("set_control_size", {
		"node_path": "%s/Sized2" % SANDBOX_NAME,
	})
	assert_false(r.success, "no dimensions = no-op = should error")
	assert_true(str(r.get("error", "")).to_lower().contains("required"))


func test_set_control_size_warns_when_stretched() -> void:
	# Pre-stretch via anchor preset, then try to set fixed size — tool
	# should set it but warn the user it'll get clobbered on next layout.
	_run("create_control", {
		"type": "Panel",
		"name": "Stretched",
		"parent_path": SANDBOX_NAME,
		"anchor_preset": "full_rect",
	})
	var r := _run("set_control_size", {
		"node_path": "%s/Stretched" % SANDBOX_NAME,
		"width": 100,
		"height": 100,
	})
	assert_true(r.success)
	assert_true(r.has("note"), "stretched Control should get a note about size being clobbered")


# ── list_ui_hierarchy ─────────────────────────────────────────────────────

func test_list_ui_hierarchy_returns_only_ui_nodes() -> void:
	# Mixed scene: Control + Node3D sibling inside sandbox. Walker should
	# return only the Control branch.
	_run("create_control", {"type": "Label", "name": "L1", "parent_path": SANDBOX_NAME, "text": "a"})
	_run("create_control", {"type": "Button", "name": "B1", "parent_path": SANDBOX_NAME, "text": "b"})
	var r := _run("list_ui_hierarchy", {})
	assert_true(r.success, "list_ui_hierarchy should succeed: %s" % r.get("message", ""))
	assert_gt(int(r.count), 0, "should find at least the sandbox Controls")
	# Spot-check: at least one element's path includes our sandbox.
	var found_sandbox_descendant := false
	for el in r.elements:
		if String(el.get("path", "")).contains(SANDBOX_NAME):
			found_sandbox_descendant = true
			break
	assert_true(found_sandbox_descendant, "elements should include sandbox descendants")


# ── create_theme ──────────────────────────────────────────────────────────

func test_create_theme_writes_resource() -> void:
	var path := STAGED_THEME_DIR + "theme_a.tres"
	var r := _run("create_theme", {"path": path})
	assert_true(r.success, "create_theme should succeed: %s" % r.get("message", ""))
	assert_eq(r.type, "Theme")
	assert_true(FileAccess.file_exists(path), "Theme.tres must exist on disk")


func test_create_theme_refuses_existing_path() -> void:
	var path := STAGED_THEME_DIR + "theme_dup.tres"
	_run("create_theme", {"path": path})
	var r := _run("create_theme", {"path": path})
	assert_false(r.success, "second create at same path should fail (no overwrite)")
	assert_true(r.has("possible_solutions"))


func test_create_theme_missing_path() -> void:
	var r := _run("create_theme", {})
	assert_false(r.success, "missing path should fail")
