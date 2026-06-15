extends GutTest

# Integration tests for the 4 v0.6.8 AnimationTree state-machine tools
# (create_animation_tree / add_state_machine_state /
# add_state_machine_transition / get_animation_tree_info).
#
# Builds a sandbox subtree under the edited scene root: a Target Node3D with an
# AnimationPlayer that has two clips ("idle", "run") registered in the default
# library. Clips are held in-memory on the player (no .tres on disk needed) —
# the state machine references them by play-name. The AnimationTree itself is
# created by the tool under test and torn down with the sandbox in after_each.

const Registry = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd")
const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const SANDBOX_NAME := "_GladeKitAnimTreeTestSandbox"
const TARGET_NAME := "Target"
const PLAYER_NAME := "AnimPlayer"

var _registry = null
var _sandbox: Node = null
var _target: Node3D = null
var _player: AnimationPlayer = null


func should_skip_script():
	# Same rationale as test_animation_tools.gd — these tools need
	# EditorInterface, unreachable under GUT's play_custom_scene runner.
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

	_target = Node3D.new()
	_target.name = TARGET_NAME
	_sandbox.add_child(_target)
	_target.owner = scene_root

	_player = AnimationPlayer.new()
	_player.name = PLAYER_NAME
	_target.add_child(_player)
	_player.owner = scene_root

	# Register two empty clips in the default ("") library so the state machine
	# has play-names to reference.
	var lib := AnimationLibrary.new()
	lib.add_animation("idle", Animation.new())
	lib.add_animation("run", Animation.new())
	_player.add_animation_library("", lib)


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


func _run(tool_name: String, args: Dictionary) -> Dictionary:
	var t = _registry.get_tool(tool_name)
	assert_not_null(t, "Tool '%s' must be registered" % tool_name)
	return t.execute(args)


func _player_path() -> String:
	return "%s/%s/%s" % [SANDBOX_NAME, TARGET_NAME, PLAYER_NAME]


func _tree_path(tree_name: String = "AnimationTree") -> String:
	return "%s/%s" % [SANDBOX_NAME, tree_name]


# Fetch the live state machine resource for white-box assertions.
func _state_machine(tree_name: String = "AnimationTree") -> AnimationNodeStateMachine:
	var node := ToolUtils.find_node_by_path(_tree_path(tree_name))
	if node == null or not (node is AnimationTree):
		return null
	return (node as AnimationTree).tree_root as AnimationNodeStateMachine


# ── create_animation_tree ─────────────────────────────────────────────────

func test_create_animation_tree_seeds_states() -> void:
	var r := _run("create_animation_tree", {
		"player_path": _player_path(),
		"parent_path": SANDBOX_NAME,
	})
	assert_true(r.success, "happy path: %s" % r.get("error", ""))
	assert_eq(r.type, "AnimationTree")
	assert_true(r.seeded, "seed_states defaults to true")
	# One state per registered clip.
	assert_eq((r.states as Array).size(), 2)
	assert_has(r.states, "idle")
	assert_has(r.states, "run")
	# Start transition wired to the first clip.
	assert_eq((r.transitions as Array).size(), 1)

	var sm := _state_machine()
	assert_not_null(sm, "tree_root must be an AnimationNodeStateMachine")
	assert_true(sm.has_node("idle"))
	assert_true(sm.has_node("run"))
	assert_true(sm.has_transition("Start", "idle"), "Start should target the initial state")

	# anim_player resolves back to our player from the tree.
	var tree := ToolUtils.find_node_by_path(_tree_path()) as AnimationTree
	assert_true(tree.active, "active defaults to true")
	assert_not_null(tree.get_node_or_null(tree.anim_player), "anim_player path must resolve")


func test_create_animation_tree_respects_initial_state() -> void:
	var r := _run("create_animation_tree", {
		"player_path": _player_path(),
		"parent_path": SANDBOX_NAME,
		"initial_state": "run",
	})
	assert_true(r.success, "initial_state=run: %s" % r.get("error", ""))
	var sm := _state_machine()
	assert_true(sm.has_transition("Start", "run"), "Start should target the chosen initial_state")


func test_create_animation_tree_empty_when_seed_false() -> void:
	var r := _run("create_animation_tree", {
		"player_path": _player_path(),
		"parent_path": SANDBOX_NAME,
		"seed_states": false,
	})
	assert_true(r.success, "seed_states=false: %s" % r.get("error", ""))
	assert_eq((r.states as Array).size(), 0)
	var sm := _state_machine()
	assert_eq(sm.get_node_list().size(), 0, "no states when seeding is off")


func test_create_animation_tree_refuses_non_player() -> void:
	var r := _run("create_animation_tree", {
		"player_path": "%s/%s" % [SANDBOX_NAME, TARGET_NAME],  # Node3D, not a player
		"parent_path": SANDBOX_NAME,
	})
	assert_false(r.success)
	assert_string_contains(r.error, "not AnimationPlayer")


# ── add_state_machine_state ───────────────────────────────────────────────

func test_add_state_machine_state_happy() -> void:
	_run("create_animation_tree", {
		"player_path": _player_path(), "parent_path": SANDBOX_NAME, "seed_states": false,
	})
	var r := _run("add_state_machine_state", {
		"tree_path": _tree_path(),
		"state_name": "idle",
	})
	assert_true(r.success, "add state: %s" % r.get("error", ""))
	assert_eq(r.state_name, "idle")
	assert_eq(r.animation, "idle", "animation defaults to state_name")
	assert_false(r.has("animation_warning"), "clip 'idle' is registered, so no warning")
	assert_eq(r.state_count, 1)
	assert_true(_state_machine().has_node("idle"))


func test_add_state_machine_state_warns_on_missing_clip() -> void:
	_run("create_animation_tree", {
		"player_path": _player_path(), "parent_path": SANDBOX_NAME, "seed_states": false,
	})
	var r := _run("add_state_machine_state", {
		"tree_path": _tree_path(),
		"state_name": "fly",
		"animation": "fly",  # not registered on the player
	})
	assert_true(r.success, "state still created even with an unregistered clip")
	assert_true(r.has("animation_warning"), "missing clip should be flagged")


func test_add_state_machine_state_refuses_reserved_and_duplicate() -> void:
	_run("create_animation_tree", {
		"player_path": _player_path(), "parent_path": SANDBOX_NAME, "seed_states": false,
	})
	var reserved := _run("add_state_machine_state", {"tree_path": _tree_path(), "state_name": "Start"})
	assert_false(reserved.success)
	assert_string_contains(reserved.error, "reserved")

	_run("add_state_machine_state", {"tree_path": _tree_path(), "state_name": "idle"})
	var dup := _run("add_state_machine_state", {"tree_path": _tree_path(), "state_name": "idle"})
	assert_false(dup.success)
	assert_string_contains(dup.error, "already exists")


# ── add_state_machine_transition ──────────────────────────────────────────

func test_add_state_machine_transition_happy() -> void:
	_run("create_animation_tree", {"player_path": _player_path(), "parent_path": SANDBOX_NAME})
	var r := _run("add_state_machine_transition", {
		"tree_path": _tree_path(),
		"from_state": "idle",
		"to_state": "run",
		"switch_mode": "at_end",
		"xfade_time": 0.25,
		"advance_mode": "auto",
		"advance_condition": "is_running",
	})
	assert_true(r.success, "add transition: %s" % r.get("error", ""))
	assert_eq(r.from_state, "idle")
	assert_eq(r.to_state, "run")
	assert_eq(r.switch_mode, "at_end")
	assert_eq(r.advance_mode, "auto")
	assert_eq(r.advance_condition, "is_running")
	assert_true(_state_machine().has_transition("idle", "run"))


func test_add_state_machine_transition_refuses_missing_state() -> void:
	_run("create_animation_tree", {"player_path": _player_path(), "parent_path": SANDBOX_NAME})
	var r := _run("add_state_machine_transition", {
		"tree_path": _tree_path(),
		"from_state": "idle",
		"to_state": "nope",
	})
	assert_false(r.success)
	assert_string_contains(r.error, "does not exist")
	assert_has(r, "possible_solutions")


func test_add_state_machine_transition_refuses_start_as_destination() -> void:
	_run("create_animation_tree", {"player_path": _player_path(), "parent_path": SANDBOX_NAME})
	var r := _run("add_state_machine_transition", {
		"tree_path": _tree_path(),
		"from_state": "idle",
		"to_state": "Start",
	})
	assert_false(r.success)
	assert_string_contains(r.error, "Start")


func test_add_state_machine_transition_refuses_duplicate() -> void:
	# create seeds Start -> idle already; re-adding it must fail.
	_run("create_animation_tree", {"player_path": _player_path(), "parent_path": SANDBOX_NAME})
	var r := _run("add_state_machine_transition", {
		"tree_path": _tree_path(),
		"from_state": "Start",
		"to_state": "idle",
	})
	assert_false(r.success)
	assert_string_contains(r.error, "already exists")


# ── get_animation_tree_info ───────────────────────────────────────────────

func test_get_animation_tree_info_reports_structure() -> void:
	_run("create_animation_tree", {"player_path": _player_path(), "parent_path": SANDBOX_NAME})
	_run("add_state_machine_transition", {
		"tree_path": _tree_path(), "from_state": "idle", "to_state": "run",
	})
	var r := _run("get_animation_tree_info", {"tree_path": _tree_path()})
	assert_true(r.success, "info: %s" % r.get("error", ""))
	assert_eq(r.root_type, "AnimationNodeStateMachine")
	assert_true(r.active)
	assert_true(r.anim_player_found)
	assert_eq(r.state_count, 2)
	# Start -> idle (seeded) + idle -> run (added) = 2 transitions.
	assert_eq(r.transition_count, 2)
	# Each seeded state reports a registered clip.
	for state in r.states:
		assert_true(state.get("animation_registered", false), "%s clip should resolve" % state.name)


func test_get_animation_tree_info_refuses_non_tree() -> void:
	var r := _run("get_animation_tree_info", {"tree_path": _player_path()})
	assert_false(r.success)
	assert_string_contains(r.error, "not AnimationTree")
