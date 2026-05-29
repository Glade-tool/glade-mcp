extends GutTest

# Verifies the Phase 1 exit-tree contract: the WS server must release port
# 8766 cleanly when stop() is called, so the next start() can re-bind
# without ERR_ALREADY_IN_USE. This is the hot-reload path that fires
# whenever a script inside the addon is edited and Godot re-enters the
# plugin tree.
#
# We exercise start → stop → start directly against ws_server.gd instead of
# going through the EditorPlugin lifecycle: that lets us run the whole
# cycle synchronously inside a single test and assert against the bind
# result without poking the live bridge instance the editor is already
# hosting.

const WsServer = preload("res://addons/com.gladekit.mcp-bridge/bridge/ws_server.gd")

# Use a non-default port so we never collide with the live bridge instance
# the editor itself is already running on 8766.
const TEST_PORT := 18799


func before_each() -> void:
	OS.set_environment("GLADEKIT_GODOT_BRIDGE_PORT", str(TEST_PORT))


func after_each() -> void:
	OS.set_environment("GLADEKIT_GODOT_BRIDGE_PORT", "")


func _spin_up() -> Node:
	var server: Node = WsServer.new()
	server.name = "GladeKitTestWsServer"
	add_child_autofree(server)
	server.start()
	return server


func test_start_stop_releases_socket() -> void:
	var first := _spin_up()
	# If start() failed (port collision, etc.), _running would be false and
	# we'd never get a clean test signal.
	assert_true(first._running, "First start() must succeed")
	first.stop()
	assert_false(first._running, "stop() must clear _running")
	# Second start on same port should succeed if the first released cleanly.
	var second := _spin_up()
	assert_true(second._running, "Second start() must rebind without EADDRINUSE")
	second.stop()


func test_double_start_is_idempotent() -> void:
	var server := _spin_up()
	# Calling start() again while already running should be a no-op (it
	# checks _running) — verifies the guard.
	server.start()
	assert_true(server._running)
	server.stop()


func test_stop_when_not_running_is_safe() -> void:
	var server: Node = WsServer.new()
	server.name = "GladeKitTestWsServer2"
	add_child_autofree(server)
	# Never called start() — stop() must be a safe no-op, not crash on the
	# null TCPServer / null thread.
	server.stop()
	assert_false(server._running)
