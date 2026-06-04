extends GutTest

# Integration tests for the 5 v0.6.0 animation tools.
#
# Drives the full scaffold flow end-to-end against a real Animation .tres
# saved to user:// (kept out of the user's project — torn down in
# after_each). The sandbox subtree under the edited scene root holds the
# target Node3D and AnimationPlayer; the Animation resource itself lives
# on disk at user://gladekit_test_anim.tres.

const Registry = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd")
const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const SANDBOX_NAME := "_GladeKitAnimTestSandbox"
const ANIM_PATH := "user://gladekit_test_anim.tres"
const TARGET_NAME := "Target"
const PLAYER_NAME := "AnimPlayer"

var _registry = null
var _sandbox: Node = null
var _target: Node3D = null
var _player: AnimationPlayer = null


func should_skip_script():
	# Same rationale as test_scene_node_tools.gd::should_skip_script — these
	# tests need EditorInterface, which is unreachable under GUT's
	# play_custom_scene runner. Skip the whole file with a clear hint.
	if ToolUtils.get_edited_scene_root_safe() == null:
		return "requires editor context (skipped under GUT play_custom_scene; verify by driving the bridge through an MCP client with the editor open)"
	return false


func before_each() -> void:
	_registry = Registry.new()
	var scene_root := EditorInterface.get_edited_scene_root()

	# Sandbox cleanup — defensive against a crashed prior run.
	var leftover := scene_root.find_child(SANDBOX_NAME, false, false)
	if leftover:
		scene_root.remove_child(leftover)
		leftover.free()

	_sandbox = Node3D.new()
	_sandbox.name = SANDBOX_NAME
	scene_root.add_child(_sandbox)
	_sandbox.owner = scene_root

	_target = Node3D.new()
	_target.name = TARGET_NAME
	_sandbox.add_child(_target)
	_target.owner = scene_root

	_player = AnimationPlayer.new()
	_player.name = PLAYER_NAME
	_target.add_child(_player)
	_player.owner = scene_root

	# Seed an empty Animation .tres so the tools have something to load.
	# user:// is project-external — keeps the test from leaving artifacts.
	var anim := Animation.new()
	var save_err := ResourceSaver.save(anim, ANIM_PATH)
	assert_eq(save_err, OK, "Test setup: ResourceSaver.save must succeed")


func after_each() -> void:
	if _sandbox != null and is_instance_valid(_sandbox):
		var parent := _sandbox.get_parent()
		if parent != null:
			parent.remove_child(_sandbox)
		_sandbox.free()
	_sandbox = null
	_target = null
	_player = null
	_registry = null

	# Clean up the on-disk .tres so reruns start from a known state.
	if FileAccess.file_exists(ANIM_PATH):
		var dir := DirAccess.open(ANIM_PATH.get_base_dir())
		if dir != null:
			dir.remove(ANIM_PATH.get_file())


func _run(tool_name: String, args: Dictionary) -> Dictionary:
	var t = _registry.get_tool(tool_name)
	assert_not_null(t, "Tool '%s' must be registered" % tool_name)
	return t.execute(args)


func _player_path() -> String:
	return "%s/%s/%s" % [SANDBOX_NAME, TARGET_NAME, PLAYER_NAME]


# ── add_animation_to_player ───────────────────────────────────────────────

func test_add_animation_to_player_happy() -> void:
	var r := _run("add_animation_to_player", {
		"player_path": _player_path(),
		"animation_path": ANIM_PATH,
		"animation_name": "jump",
	})
	assert_true(r.success, "happy path: %s" % r.get("error", ""))
	assert_eq(r.animation_name, "jump")
	assert_eq(r.library_name, "")
	assert_true(r.library_created, "library should be auto-created on first registration")
	assert_eq(r.library_animation_count, 1)
	# Player state should reflect the addition.
	assert_true(_player.has_animation_library(""))
	assert_true(_player.get_animation_library("").has_animation("jump"))


func test_add_animation_to_player_refuses_duplicate() -> void:
	_run("add_animation_to_player", {
		"player_path": _player_path(),
		"animation_path": ANIM_PATH,
		"animation_name": "jump",
	})
	var r := _run("add_animation_to_player", {
		"player_path": _player_path(),
		"animation_path": ANIM_PATH,
		"animation_name": "jump",
	})
	assert_false(r.success)
	assert_string_contains(r.error, "already registered")
	# possible_solutions must be present so the agent can recover.
	assert_has(r, "possible_solutions")


func test_add_animation_to_player_refuses_non_player_target() -> void:
	var r := _run("add_animation_to_player", {
		"player_path": "%s/%s" % [SANDBOX_NAME, TARGET_NAME],  # Node3D, not AnimationPlayer
		"animation_path": ANIM_PATH,
		"animation_name": "jump",
	})
	assert_false(r.success)
	assert_string_contains(r.error, "not AnimationPlayer")


# ── add_animation_track ───────────────────────────────────────────────────

func test_add_animation_track_position_3d() -> void:
	var r := _run("add_animation_track", {
		"animation_path": ANIM_PATH,
		"track_type": "position_3d",
		"node_path": "..",
	})
	assert_true(r.success, "position_3d track: %s" % r.get("error", ""))
	assert_eq(r.track_index, 0)
	assert_eq(r.track_type, "position_3d")
	assert_eq(r.track_count, 1)
	# Verify on disk — the resource was saved.
	var loaded = ResourceLoader.load(ANIM_PATH)
	assert_true(loaded is Animation)
	assert_eq((loaded as Animation).get_track_count(), 1)


func test_add_animation_track_value_requires_property() -> void:
	var r := _run("add_animation_track", {
		"animation_path": ANIM_PATH,
		"track_type": "value",
		"node_path": "..",
		# missing `property` — should error noisily with hints
	})
	assert_false(r.success)
	assert_string_contains(r.error, "property")
	assert_has(r, "possible_solutions")


func test_add_animation_track_unknown_type_lists_options() -> void:
	var r := _run("add_animation_track", {
		"animation_path": ANIM_PATH,
		"track_type": "bogus_track_type",
		"node_path": "..",
	})
	assert_false(r.success)
	assert_string_contains(r.error, "Unknown track_type")
	# Error must list the valid options so the agent can self-correct.
	assert_has(r, "possible_solutions")
	var solutions: Array = r.possible_solutions
	assert_string_contains(solutions[0], "position_3d")


# ── add_animation_keyframe ────────────────────────────────────────────────

func test_add_animation_keyframe_position_3d_string_value() -> void:
	# Seed a track first.
	_run("add_animation_track", {
		"animation_path": ANIM_PATH,
		"track_type": "position_3d",
		"node_path": "..",
	})
	# Insert a key with the agent-natural "x,y,z" string form.
	var r := _run("add_animation_keyframe", {
		"animation_path": ANIM_PATH,
		"track_index": 0,
		"time": 0.3,
		"value": "0,2,0",
	})
	assert_true(r.success, "position_3d key: %s" % r.get("error", ""))
	assert_eq(r.key_count, 1)
	# Reload and verify the actual stored value.
	var loaded: Animation = ResourceLoader.load(ANIM_PATH)
	var pos: Vector3 = loaded.track_get_key_value(0, 0)
	assert_eq(pos, Vector3(0, 2, 0))


func test_add_animation_keyframe_rotation_3d_euler_string() -> void:
	# rotation_3d auto-converts "x,y,z" Euler degrees → Quaternion.
	_run("add_animation_track", {
		"animation_path": ANIM_PATH,
		"track_type": "rotation_3d",
		"node_path": "..",
	})
	var r := _run("add_animation_keyframe", {
		"animation_path": ANIM_PATH,
		"track_index": 0,
		"time": 0.0,
		"value": "0,90,0",  # 90° yaw — natural form for the agent
	})
	assert_true(r.success, "rotation_3d key: %s" % r.get("error", ""))
	# Round-trip: 90° yaw → Quaternion(0, sin(45°), 0, cos(45°)).
	var loaded: Animation = ResourceLoader.load(ANIM_PATH)
	var q: Quaternion = loaded.track_get_key_value(0, 0)
	# Compare via euler — float-tolerant.
	var euler := q.get_euler()
	assert_almost_eq(rad_to_deg(euler.y), 90.0, 0.01)


func test_add_animation_keyframe_out_of_range_track() -> void:
	var r := _run("add_animation_keyframe", {
		"animation_path": ANIM_PATH,
		"track_index": 42,
		"time": 0.0,
		"value": "0,0,0",
	})
	assert_false(r.success)
	assert_string_contains(r.error, "out of range")


# ── set_animation_properties ──────────────────────────────────────────────

func test_set_animation_properties_length_and_loop_mode() -> void:
	var r := _run("set_animation_properties", {
		"animation_path": ANIM_PATH,
		"length": 0.6,
		"loop_mode": "linear",
	})
	assert_true(r.success, "set props: %s" % r.get("error", ""))
	assert_eq(r.applied.length, 0.6)
	assert_eq(r.applied.loop_mode, 1)
	# Verify on disk.
	var loaded: Animation = ResourceLoader.load(ANIM_PATH)
	assert_almost_eq(loaded.length, 0.6, 0.001)
	assert_eq(loaded.loop_mode, 1)


func test_set_animation_properties_empty_call_refused() -> void:
	# Mirrors set_node_transform's 0.5.8 noisy-refusal pattern.
	var r := _run("set_animation_properties", {
		"animation_path": ANIM_PATH,
	})
	assert_false(r.success)
	assert_string_contains(r.error, "at least one")
	assert_has(r, "possible_solutions")


func test_set_animation_properties_invalid_loop_mode() -> void:
	var r := _run("set_animation_properties", {
		"animation_path": ANIM_PATH,
		"loop_mode": "loop_forever_pretty_please",
	})
	assert_false(r.success)
	assert_string_contains(r.error, "Invalid loop_mode")


# ── get_animation_player_info ─────────────────────────────────────────────

func test_get_animation_player_info_empty_player() -> void:
	var r := _run("get_animation_player_info", {"player_path": _player_path()})
	assert_true(r.success, "empty player info: %s" % r.get("error", ""))
	assert_eq(r.library_count, 0)
	assert_eq(r.total_animations, 0)
	assert_false(r.is_playing)


func test_get_animation_player_info_after_registration() -> void:
	_run("add_animation_to_player", {
		"player_path": _player_path(),
		"animation_path": ANIM_PATH,
		"animation_name": "jump",
	})
	var r := _run("get_animation_player_info", {"player_path": _player_path()})
	assert_true(r.success)
	assert_eq(r.library_count, 1)
	assert_eq(r.total_animations, 1)
	var libraries: Dictionary = r.libraries
	assert_true(libraries.has(""))
	assert_eq((libraries[""] as Array)[0], "jump")


func test_get_animation_player_info_non_player_target() -> void:
	var r := _run("get_animation_player_info", {
		"player_path": "%s/%s" % [SANDBOX_NAME, TARGET_NAME],
	})
	assert_false(r.success)
	assert_string_contains(r.error, "not AnimationPlayer")


# ── End-to-end scaffold flow ──────────────────────────────────────────────

func test_full_jump_scaffold_flow() -> void:
	# Mirrors the schema doc's "add a 0.6s jump animation" example.
	# Establishes the complete agent-facing workflow works end-to-end.
	var add_r := _run("add_animation_to_player", {
		"player_path": _player_path(),
		"animation_path": ANIM_PATH,
		"animation_name": "jump",
	})
	assert_true(add_r.success)

	var track_r := _run("add_animation_track", {
		"animation_path": ANIM_PATH,
		"track_type": "position_3d",
		"node_path": "..",
	})
	assert_true(track_r.success)
	var track_index: int = track_r.track_index

	# 3 keys: ground → peak → ground
	for entry in [["0.0", "0,0,0"], ["0.3", "0,2,0"], ["0.6", "0,0,0"]]:
		var k_r := _run("add_animation_keyframe", {
			"animation_path": ANIM_PATH,
			"track_index": track_index,
			"time": float(entry[0]),
			"value": entry[1],
		})
		assert_true(k_r.success, "keyframe %s failed: %s" % [entry, k_r.get("error", "")])

	var props_r := _run("set_animation_properties", {
		"animation_path": ANIM_PATH,
		"length": 0.6,
		"loop_mode": "none",
	})
	assert_true(props_r.success)

	# Verify the final state via the read-only inspector.
	var info_r := _run("get_animation_player_info", {"player_path": _player_path()})
	assert_true(info_r.success)
	assert_eq(info_r.total_animations, 1)
	assert_eq((info_r.libraries[""] as Array)[0], "jump")

	# Verify the .tres carries the expected shape.
	var loaded: Animation = ResourceLoader.load(ANIM_PATH)
	assert_eq(loaded.get_track_count(), 1)
	assert_eq(loaded.track_get_key_count(0), 3)
	assert_almost_eq(loaded.length, 0.6, 0.001)
	assert_eq(loaded.loop_mode, 0)
