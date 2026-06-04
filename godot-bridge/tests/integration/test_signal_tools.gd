extends GutTest

# Integration tests for the Phase 5 signal tools. Spawns a sandbox node
# with a known emitter (Timer — has the well-known `timeout` signal) and a
# receiver Node with a script defining `_on_timer_timeout()`. Verifies
# connect / list / disconnect happy paths and the actionable-error paths
# (missing signal, missing method, double-disconnect).

const Registry = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd")
const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const SANDBOX_NAME := "_GladeKitSignalSandbox"
const EMITTER_NAME := "TestTimer"
const RECEIVER_NAME := "TestReceiver"

var _registry = null
var _sandbox: Node = null


func should_skip_script():
	# Integration tests require a live editor + edited scene. Under GUT's
	# play_custom_scene runner, EditorInterface isn't accessible — every
	# test in this file would crash on the first scene-tree call. Skip
	# the whole script with a clear message instead. To exercise these
	# tests, drive the bridge through an MCP client with the editor open.
	if ToolUtils.get_edited_scene_root_safe() == null:
		return "requires editor context (skipped under GUT play_custom_scene; verify by driving the bridge through an MCP client with the editor open)"
	return false


func before_each() -> void:
	_registry = Registry.new()
	var scene_root := EditorInterface.get_edited_scene_root()
	# Clean any leftover from a previous test.
	var leftover := scene_root.find_child(SANDBOX_NAME, false, false)
	if leftover:
		scene_root.remove_child(leftover)
		leftover.free()
	# Build sandbox: emitter (Timer) + receiver (Node with a tiny script
	# that declares `_on_timer_timeout`). Both as descendants of the
	# scene root so node_relative_path resolves cleanly.
	_sandbox = Node.new()
	_sandbox.name = SANDBOX_NAME
	scene_root.add_child(_sandbox)
	_sandbox.owner = scene_root

	var emitter := Timer.new()
	emitter.name = EMITTER_NAME
	_sandbox.add_child(emitter)
	emitter.owner = scene_root

	var receiver := Node.new()
	receiver.name = RECEIVER_NAME
	# Inline GDScript with one handler — sufficient for has_method() checks.
	var script := GDScript.new()
	script.source_code = """
extends Node
func _on_timer_timeout() -> void:
	pass
"""
	script.reload()
	receiver.set_script(script)
	_sandbox.add_child(receiver)
	receiver.owner = scene_root


func after_each() -> void:
	if _sandbox != null and is_instance_valid(_sandbox):
		var p := _sandbox.get_parent()
		if p != null:
			p.remove_child(_sandbox)
		_sandbox.free()
	_sandbox = null
	_registry = null


func _run(tool_name: String, args: Dictionary) -> Dictionary:
	var t = _registry.get_tool(tool_name)
	assert_not_null(t, "Tool '%s' must be registered" % tool_name)
	return t.execute(args)


func _emitter_path() -> String:
	return "%s/%s" % [SANDBOX_NAME, EMITTER_NAME]


func _receiver_path() -> String:
	return "%s/%s" % [SANDBOX_NAME, RECEIVER_NAME]


# ── connect_signal ────────────────────────────────────────────────────────

func test_connect_signal_happy() -> void:
	var r := _run("connect_signal", {
		"emitter_path": _emitter_path(),
		"signal_name": "timeout",
		"target_path": _receiver_path(),
		"method_name": "_on_timer_timeout",
	})
	assert_true(r.success, "connect should succeed: %s" % r.get("message", ""))
	assert_eq(r.connection.signal_name, "timeout")
	assert_false(r.connection.already_connected)
	assert_true(r.connection.flags.has("persist"), "persist flag must be forced on")


func test_connect_signal_is_idempotent() -> void:
	var args := {
		"emitter_path": _emitter_path(),
		"signal_name": "timeout",
		"target_path": _receiver_path(),
		"method_name": "_on_timer_timeout",
	}
	_run("connect_signal", args)
	var r := _run("connect_signal", args)
	assert_true(r.success, "Re-connecting should succeed (no-op)")
	assert_true(r.connection.already_connected, "Second call must report already_connected")


func test_connect_signal_unknown_signal_returns_solutions() -> void:
	var r := _run("connect_signal", {
		"emitter_path": _emitter_path(),
		"signal_name": "timeput",  # typo of "timeout"
		"target_path": _receiver_path(),
		"method_name": "_on_timer_timeout",
	})
	assert_false(r.success)
	assert_true(r.has("possible_solutions"))
	assert_true(r.has("available_signals"))
	# At least one suggestion should namedrop the right signal so the
	# agent can self-correct without a second list call.
	var suggestions_joined := ""
	for s in r.possible_solutions:
		suggestions_joined += String(s)
	assert_string_contains(suggestions_joined.to_lower(), "timeout")


func test_connect_signal_unknown_method_returns_solutions() -> void:
	var r := _run("connect_signal", {
		"emitter_path": _emitter_path(),
		"signal_name": "timeout",
		"target_path": _receiver_path(),
		"method_name": "_on_timer_typo",
	})
	assert_false(r.success)
	assert_true(r.has("possible_solutions"))
	# The right method should appear in suggestions for the agent.
	var suggestions_joined := ""
	for s in r.possible_solutions:
		suggestions_joined += String(s)
	assert_string_contains(suggestions_joined, "_on_timer_timeout")


func test_connect_signal_missing_emitter() -> void:
	var r := _run("connect_signal", {
		"emitter_path": "Bogus/Path",
		"signal_name": "timeout",
		"target_path": _receiver_path(),
		"method_name": "_on_timer_timeout",
	})
	assert_false(r.success)
	assert_string_contains(r.error, "not found")


func test_connect_signal_missing_required_arg() -> void:
	# Missing target_path
	var r := _run("connect_signal", {
		"emitter_path": _emitter_path(),
		"signal_name": "timeout",
		"method_name": "_on_timer_timeout",
	})
	assert_false(r.success)
	assert_string_contains(r.error, "target_path")


# ── list_signal_connections ────────────────────────────────────────────────

func test_list_signal_connections_outgoing() -> void:
	_run("connect_signal", {
		"emitter_path": _emitter_path(),
		"signal_name": "timeout",
		"target_path": _receiver_path(),
		"method_name": "_on_timer_timeout",
	})
	var r := _run("list_signal_connections", {
		"node_path": _emitter_path(),
		"direction": "out",
	})
	assert_true(r.success)
	assert_eq(r.count, 1)
	var conn = r.connections[0]
	assert_eq(conn.signal, "timeout")
	assert_eq(conn.direction, "out")
	assert_true(conn.persistent)


func test_list_signal_connections_incoming() -> void:
	_run("connect_signal", {
		"emitter_path": _emitter_path(),
		"signal_name": "timeout",
		"target_path": _receiver_path(),
		"method_name": "_on_timer_timeout",
	})
	var r := _run("list_signal_connections", {
		"node_path": _receiver_path(),
		"direction": "in",
	})
	assert_true(r.success)
	assert_eq(r.count, 1)
	var conn = r.connections[0]
	assert_eq(conn.direction, "in")
	assert_eq(conn.method, "_on_timer_timeout")


func test_list_signal_connections_detailed_lists_available() -> void:
	var r := _run("list_signal_connections", {
		"node_path": _emitter_path(),
		"response_format": "detailed",
	})
	assert_true(r.success)
	assert_true(r.has("available_signals"))
	# Timer declares `timeout` — must show up in the available list.
	var saw_timeout: bool = false
	for sig in r.available_signals:
		if String(sig.get("name", "")) == "timeout":
			saw_timeout = true
			break
	assert_true(saw_timeout, "Timer's `timeout` should appear in available_signals")


func test_list_signal_connections_signal_filter() -> void:
	_run("connect_signal", {
		"emitter_path": _emitter_path(),
		"signal_name": "timeout",
		"target_path": _receiver_path(),
		"method_name": "_on_timer_timeout",
	})
	var r := _run("list_signal_connections", {
		"node_path": _emitter_path(),
		"signal_name": "tree_entered",  # different signal, should produce zero
		"direction": "out",
	})
	assert_true(r.success)
	assert_eq(r.count, 0)


func test_list_signal_connections_invalid_direction() -> void:
	var r := _run("list_signal_connections", {
		"node_path": _emitter_path(),
		"direction": "sideways",
	})
	assert_false(r.success)


# ── disconnect_signal ──────────────────────────────────────────────────────

func test_disconnect_signal_happy() -> void:
	var args := {
		"emitter_path": _emitter_path(),
		"signal_name": "timeout",
		"target_path": _receiver_path(),
		"method_name": "_on_timer_timeout",
	}
	_run("connect_signal", args)
	var r := _run("disconnect_signal", args)
	assert_true(r.success)
	assert_eq(r.removed.signal_name, "timeout")

	# Verify it's actually gone via list_signal_connections.
	var listed := _run("list_signal_connections", {
		"node_path": _emitter_path(),
		"direction": "out",
		"signal_name": "timeout",
	})
	assert_eq(listed.count, 0)


func test_disconnect_signal_refuses_when_no_connection() -> void:
	# No connect call beforehand — must error, not silently no-op.
	var r := _run("disconnect_signal", {
		"emitter_path": _emitter_path(),
		"signal_name": "timeout",
		"target_path": _receiver_path(),
		"method_name": "_on_timer_timeout",
	})
	assert_false(r.success)
	assert_string_contains(r.error.to_lower(), "no connection")
