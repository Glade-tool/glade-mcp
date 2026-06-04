extends GutTest

# Integration tests for add_input_action. The tool persists to project.godot
# via ProjectSettings.save(), so every test uses a throwaway, clearly-namespaced
# action name and after_each fully removes it from both ProjectSettings and the
# live InputMap (then re-saves) — the dev project's real input map is never
# left mutated.

const Registry = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd")
const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const TEST_ACTION := "_gladekit_test_move"


var _registry = null


func should_skip_script():
	# add_input_action touches ProjectSettings / InputMap, which need editor
	# context. See test_signal_tools.gd::should_skip_script for the full story.
	if ToolUtils.get_edited_scene_root_safe() == null:
		return "requires editor context (skipped under GUT play_custom_scene; verify by driving the bridge through an MCP client with the editor open)"
	return false


func before_each() -> void:
	_registry = Registry.new()
	_cleanup()


func after_each() -> void:
	_cleanup()
	_registry = null


func _cleanup() -> void:
	var setting := "input/" + TEST_ACTION
	var dirty := false
	if ProjectSettings.has_setting(setting):
		ProjectSettings.set_setting(setting, null)
		dirty = true
	if InputMap.has_action(TEST_ACTION):
		InputMap.erase_action(TEST_ACTION)
	if dirty:
		ProjectSettings.save()


func _run(args: Dictionary) -> Dictionary:
	var t = _registry.get_tool("add_input_action")
	assert_not_null(t, "add_input_action must be registered")
	return t.execute(args)


# ── Happy paths ───────────────────────────────────────────────────────────

func test_creates_action_and_registers_live() -> void:
	var r := _run({"action_name": TEST_ACTION, "keys": ["W", "Up"]})
	assert_true(r.success, "should succeed: %s" % r.get("message", ""))
	assert_eq(r.action_name, TEST_ACTION)
	assert_true(r.created, "first creation reports created=true")
	# Persisted to project settings AND live in the InputMap.
	assert_true(ProjectSettings.has_setting("input/" + TEST_ACTION))
	assert_true(InputMap.has_action(TEST_ACTION))
	assert_eq((r.keys as Array).size(), 2)


func test_overwrite_updates_existing_reports_not_created() -> void:
	_run({"action_name": TEST_ACTION, "keys": ["W"]})
	var r := _run({"action_name": TEST_ACTION, "keys": ["A", "Left"]})
	assert_true(r.success)
	assert_false(r.created, "second call on existing action reports created=false")


func test_overwrite_false_on_existing_is_refused() -> void:
	_run({"action_name": TEST_ACTION, "keys": ["W"]})
	var r := _run({"action_name": TEST_ACTION, "keys": ["A"], "overwrite": false})
	assert_false(r.success)
	assert_string_contains(r.error, "already exists")


# ── Validation ──────────────────────────────────────────────────────────────

func test_missing_action_name_is_error() -> void:
	var r := _run({"keys": ["W"]})
	assert_false(r.success)
	assert_string_contains(r.error, "action_name")


func test_missing_keys_is_error() -> void:
	var r := _run({"action_name": TEST_ACTION})
	assert_false(r.success)
	assert_string_contains(r.error, "keys")


func test_empty_keys_array_is_error() -> void:
	var r := _run({"action_name": TEST_ACTION, "keys": []})
	assert_false(r.success)
	assert_string_contains(r.error, "keys")


func test_unrecognized_key_is_error_with_solutions() -> void:
	var r := _run({"action_name": TEST_ACTION, "keys": ["NotARealKey"]})
	assert_false(r.success)
	assert_string_contains(r.error, "Unrecognized key")
	assert_true(r.has("possible_solutions"))
	# Nothing should have been persisted on a validation failure.
	assert_false(ProjectSettings.has_setting("input/" + TEST_ACTION))
