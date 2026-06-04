extends GutTest

# End-to-end WebSocket round-trip test. Boots a real WS server on a
# non-default port and sends actual JSON frames through a WebSocketPeer
# client — the only test that exercises the full marshal pipeline
# (peer.send_text → _thread_handle_packet → main-thread dispatch →
# _enqueue_send → _thread_send → peer.get_packet).
#
# Existing tests call tool registry execute() in-process; that catches
# tool-level logic bugs but not wire-shape regressions (response missing a
# field, JSON encoding boundary cases, threading queue races). This test
# closes that gap with a couple of fast probes — health (worker-thread-only,
# no main-thread marshaling) and tools/list (also worker-thread-only) plus
# a tools/execute round-trip for a pure read-only tool that doesn't need a
# loaded scene (get_project_info).
#
# Timing: WebSocketPeer handshake takes ~50-200ms locally. Each poll loop
# below caps at 2s with 20ms granularity. Tests use OS.delay_msec for the
# poll cadence so we don't depend on GUT's tree-tick timing.

const WsServer = preload("res://addons/com.gladekit.mcp-bridge/bridge/ws_server.gd")
const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const TEST_PORT := 18800
const CONNECT_TIMEOUT_MS := 2000
const RESPONSE_TIMEOUT_MS := 3000
const POLL_INTERVAL_MS := 20

var _server: Node = null


func before_each() -> void:
	# Force the WS server to bind a port the live bridge instance isn't using.
	OS.set_environment("GLADEKIT_GODOT_BRIDGE_PORT", str(TEST_PORT))
	_server = WsServer.new()
	_server.name = "GladeKitWsE2EServer"
	add_child_autofree(_server)
	_server.start()
	assert_true(_server._running, "Test WS server must start (port collision or bind error?)")


func after_each() -> void:
	if _server != null and is_instance_valid(_server):
		_server.stop()
	OS.set_environment("GLADEKIT_GODOT_BRIDGE_PORT", "")
	_server = null


# ── Helpers ───────────────────────────────────────────────────────────────

func _connect() -> WebSocketPeer:
	var ws := WebSocketPeer.new()
	# Disable handshake compression — keeps the frames small and avoids the
	# permessage-deflate negotiation overhead on a localhost loopback.
	var url := "ws://127.0.0.1:%d" % TEST_PORT
	var err := ws.connect_to_url(url)
	assert_eq(err, OK, "connect_to_url should succeed: err=%d" % err)
	var deadline: int = Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
	while ws.get_ready_state() == WebSocketPeer.STATE_CONNECTING and Time.get_ticks_msec() < deadline:
		ws.poll()
		# await create_timer.timeout (not OS.delay_msec) yields to the engine
		# so the bridge's _process can tick and drive its main-thread dispatch
		# queue. OS.delay_msec blocks the main thread and deadlocks any test
		# that needs tools/execute (those marshal to main thread).
		await get_tree().create_timer(POLL_INTERVAL_MS / 1000.0).timeout
	assert_eq(ws.get_ready_state(), WebSocketPeer.STATE_OPEN, "WS handshake didn't complete within %dms" % CONNECT_TIMEOUT_MS)
	return ws


func _request(ws: WebSocketPeer, request: Dictionary) -> Dictionary:
	# Frame + send.
	var send_err := ws.send_text(JSON.stringify(request))
	assert_eq(send_err, OK, "send_text should succeed: err=%d" % send_err)
	# Poll until a packet arrives. tools/execute requests are marshaled to
	# the bridge's main-thread dispatch queue — yielding via await
	# create_timer (not OS.delay_msec) lets _process tick on the bridge
	# node so the queue drains. OS.delay_msec would block the main thread
	# and deadlock this loop.
	var deadline: int = Time.get_ticks_msec() + RESPONSE_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		ws.poll()
		if ws.get_available_packet_count() > 0:
			var raw := ws.get_packet().get_string_from_utf8()
			var parsed = JSON.parse_string(raw)
			assert_true(parsed is Dictionary, "Response should parse as JSON object: %s" % raw)
			return parsed
		await get_tree().create_timer(POLL_INTERVAL_MS / 1000.0).timeout
	assert_true(false, "No response within %dms for request %s" % [RESPONSE_TIMEOUT_MS, JSON.stringify(request)])
	return {}


# ── Tests ─────────────────────────────────────────────────────────────────

func test_health_round_trip() -> void:
	var ws: WebSocketPeer = await _connect()
	var resp: Dictionary = await _request(ws, {"id": "h-1", "endpoint": "health"})
	assert_eq(resp.get("id", ""), "h-1", "id should round-trip verbatim")
	assert_true(resp.get("success", false), "health should succeed: %s" % resp)
	assert_eq(resp.get("status", ""), "ok")
	# Bridge metadata — version must be read from plugin.cfg (non-empty)
	# and bridge kind must be the godot-mcp constant.
	assert_ne(resp.get("bridgeVersion", ""), "", "bridgeVersion must not be empty")
	assert_eq(resp.get("bridgeKind", ""), "godot-mcp")
	assert_gt(int(resp.get("toolCount", 0)), 30, "toolCount should reflect registered tools (>30 expected)")
	ws.close()


func test_tools_list_round_trip() -> void:
	var ws: WebSocketPeer = await _connect()
	var resp: Dictionary = await _request(ws, {"id": "tl-1", "endpoint": "tools/list"})
	assert_true(resp.get("success", false), "tools/list should succeed")
	var tools = resp.get("tools", null)
	assert_true(tools is Array, "tools field should be an Array")
	assert_gt((tools as Array).size(), 30, "should expose >30 tools")
	# Spot-check a few names that must always be present.
	assert_true((tools as Array).has("get_scene_tree"), "scene tools must register")
	assert_true((tools as Array).has("create_node"), "create_node must register")
	assert_true((tools as Array).has("get_project_info"), "project tools must register")
	ws.close()


func test_tools_execute_round_trip_read_only() -> void:
	# Exercise the full pipeline including main-thread marshaling. Use
	# get_project_info because it's a pure read with no scene-state
	# requirements — works whether or not a scene is loaded.
	#
	# Per-test gate (not whole-file should_skip_script) because the other
	# WS layer tests in this file don't touch the editor and should still
	# run under GUT's play_custom_scene.
	if ToolUtils.get_edited_scene_root_safe() == null:
		pending("get_project_info reaches into EditorInterface; skip under play_custom_scene")
		return
	var ws: WebSocketPeer = await _connect()
	var resp: Dictionary = await _request(ws, {
		"id": "te-1",
		"endpoint": "tools/execute",
		"toolName": "get_project_info",
		"arguments": {},
	})
	assert_eq(resp.get("id", ""), "te-1", "id round-trips through main-thread queue")
	assert_true(resp.get("success", false), "get_project_info should succeed: %s" % resp)
	assert_true(resp.has("project"), "response must carry the project payload")
	ws.close()


func test_unknown_endpoint_returns_structured_error() -> void:
	# Negative path — server must reject cleanly, not drop the connection.
	var ws: WebSocketPeer = await _connect()
	var resp: Dictionary = await _request(ws, {"id": "err-1", "endpoint": "not/a/real/endpoint"})
	assert_false(resp.get("success", true), "unknown endpoint should fail")
	assert_eq(resp.get("id", ""), "err-1")
	# Connection should still be open after a bad request — verify by
	# making a second call.
	var resp2: Dictionary = await _request(ws, {"id": "err-2", "endpoint": "health"})
	assert_true(resp2.get("success", false), "connection should survive a bad request")
	ws.close()


func test_unknown_tool_returns_structured_error() -> void:
	var ws: WebSocketPeer = await _connect()
	var resp: Dictionary = await _request(ws, {
		"id": "ut-1",
		"endpoint": "tools/execute",
		"toolName": "definitely_not_a_real_tool",
		"arguments": {},
	})
	assert_false(resp.get("success", true), "unknown tool should fail")
	assert_true(str(resp.get("error", "")).contains("definitely_not_a_real_tool"))
	ws.close()


# Regression: context/gather now reports atomic success (success=false when
# any sub-fetch failed). Verify the happy-path shape AND the no-op-when-all-
# succeed contract — agents that only check `success` must be able to trust
# it instead of silently consuming partial context.
func test_context_gather_atomic_success_when_all_subfetches_succeed() -> void:
	# context/gather aggregates get_project_info + get_scene_tree, both
	# of which need editor context. Per-test gate (same rationale as
	# test_tools_execute_round_trip_read_only).
	if ToolUtils.get_edited_scene_root_safe() == null:
		pending("context/gather aggregates editor-only tools; skip under play_custom_scene")
		return
	var ws: WebSocketPeer = await _connect()
	var resp: Dictionary = await _request(ws, {"id": "cg-1", "endpoint": "context/gather"})
	# Edited scene + project_info should both succeed in a normal test run.
	# If `success` is false here, inspect resp.errors to find which sub-tool
	# regressed.
	assert_true(
		resp.get("success", false),
		"context/gather should succeed when sub-fetches succeed: %s" % resp.get("errors", "{}"),
	)
	# When everything works the `errors` field MUST be absent — it's the
	# signal clients use to decide whether the partial payload is safe to
	# trust or whether to retry/back off.
	assert_false(resp.has("errors"), "errors field must be absent when all sub-fetches succeed")
	# Payload shape probes — these were the existing contract.
	assert_true(resp.has("project"), "response must carry project payload")
	assert_true(resp.has("scene_tree"), "response must carry scene_tree payload")
	assert_true(resp.has("recent_errors"), "response must carry recent_errors payload")
	ws.close()


func test_malformed_json_returns_structured_error() -> void:
	# Send a non-JSON-object payload (a bare string). Server should answer
	# with an error frame, not crash the worker thread or close the socket.
	var ws: WebSocketPeer = await _connect()
	var send_err := ws.send_text("not actually json")
	assert_eq(send_err, OK)
	# Same async poll pattern as _request — yield to engine via timer.timeout
	# instead of blocking the main thread with OS.delay_msec.
	var deadline: int = Time.get_ticks_msec() + RESPONSE_TIMEOUT_MS
	var got_response := false
	while Time.get_ticks_msec() < deadline:
		ws.poll()
		if ws.get_available_packet_count() > 0:
			var raw := ws.get_packet().get_string_from_utf8()
			var parsed = JSON.parse_string(raw)
			assert_true(parsed is Dictionary, "Server should respond with a JSON error frame, got: %s" % raw)
			assert_false(bool(parsed.get("success", true)), "malformed input should yield success=false")
			got_response = true
			break
		await get_tree().create_timer(POLL_INTERVAL_MS / 1000.0).timeout
	assert_true(got_response, "Server didn't respond to malformed JSON within deadline")
	# Connection should survive — sanity-check with a real follow-up.
	var resp2: Dictionary = await _request(ws, {"id": "after-bad", "endpoint": "health"})
	assert_true(resp2.get("success", false), "connection must survive malformed input")
	ws.close()
