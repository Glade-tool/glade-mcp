@tool
extends Node

# WebSocket server for the GladeKit MCP Bridge.
#
# Architecture: a background Thread owns the WebSocket I/O loop (TCPServer
# accept, WebSocketPeer.poll, send_text). This decouples the bridge from the
# editor's frame loop, which is critical because Godot's editor aggressively
# throttles its main loop when unfocused (~20Hz via
# unfocused_low_processor_mode_sleep_usec) — gating p99 latency at ~100ms+.
# An editor plugin can't reliably override the editor's focus-aware throttle.
# Running our own thread sidesteps the issue.
#
# Why WebSocket instead of HTTP:
#   Godot has no built-in HTTP server primitive. WebSocketPeer + TCPServer
#   give us a battle-tested, RFC-compliant transport without rolling an
#   HTTP/1.1 parser in GDScript.
#
# Endpoint thread-safety:
#   - "health" + "tools/list": pure metadata, answered directly by the
#     thread. Fast regardless of editor focus.
#   - "tools/execute": tools touch the editor's scene tree, which is
#     main-thread-only. We marshal across via a Mutex-protected queue.
#     Main-thread dispatch is still editor-tick-bound, but tool work
#     naturally dominates the wall clock anyway.
#
# Wire protocol (newline-free JSON text frames):
#
#   REQUEST:
#     { "id": "req-1",
#       "endpoint": "health" | "tools/list" | "tools/execute",
#       "toolName":  "...",   // for tools/execute
#       "arguments": "..." | {...}  // JSON string or dict, for tools/execute
#     }
#
#   RESPONSE (success):
#     { "id": "req-1", "success": true, "message": "...", ...payload }
#
#   RESPONSE (error):
#     { "id": "req-1", "success": false, "error": "...", "message": "..." }
#
# The 'id' field is echoed verbatim so async clients can correlate.

# VERSION is read dynamically from plugin.cfg at startup — see _read_version().
# A hardcoded const here drifted in 0.3.1 -> 0.4.0 (smoke test caught it), so
# we make plugin.cfg the single source of truth for the on-the-wire version.
const PLUGIN_CFG_PATH := "res://addons/com.gladekit.mcp-bridge/plugin.cfg"
const BRIDGE_KIND := "godot-mcp"
const DEFAULT_PORT := 8766
const BIND_ADDRESS := "127.0.0.1"
const THREAD_POLL_SLEEP_MSEC := 5  # ~200Hz worker loop (never throttled)

const ToolRegistry  = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd")
const ToolUtils     = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const EngineMode    = preload("res://addons/com.gladekit.mcp-bridge/bridge/engine_mode.gd")
const ReadOnlyGuard = preload("res://addons/com.gladekit.mcp-bridge/services/read_only_guard.gd")
const ErrorTracker  = preload("res://addons/com.gladekit.mcp-bridge/services/error_tracker.gd")

# ── Bridge state ─────────────────────────────────────────────────────────
# Populated once in start() from plugin.cfg, then read-only for the rest of
# the bridge's lifetime — safe to read from the worker thread without a mutex.
var VERSION: String = "unknown"

var _tcp_server: TCPServer = null
var _peers: Array[WebSocketPeer] = []  # thread-owned after start()
var _registry = null
var _port: int = DEFAULT_PORT
var _running: bool = false

# ── Threading ────────────────────────────────────────────────────────────
var _thread: Thread = null
var _thread_should_exit: bool = false

# Thread → Main: tool/execute requests requiring scene-tree access.
var _pending_main_dispatches: Array = []
var _pending_main_dispatches_mutex: Mutex = null

# Main → Thread (or Thread → Thread): JSON responses ready to send.
var _pending_sends: Array = []
var _pending_sends_mutex: Mutex = null

# Cached engine mode, refreshed by main thread, read by worker thread.
var _cached_engine_mode: String = "edit"
var _cached_mutex: Mutex = null

# ── Diagnostics ──────────────────────────────────────────────────────────
var _accept_log_count: int = 0


# ── Lifecycle (main thread) ──────────────────────────────────────────────

func start() -> void:
	if _running:
		return
	# Resolve VERSION before anything reads it. Must happen before _thread
	# spawns (the worker thread reads VERSION on every health request).
	VERSION = _read_version()
	_port = _resolve_port()
	_registry = ToolRegistry.new()
	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(_port, BIND_ADDRESS)
	if err != OK:
		_handle_bind_failure(err)
		_tcp_server = null
		return
	_running = true
	_pending_main_dispatches_mutex = Mutex.new()
	_pending_sends_mutex = Mutex.new()
	_cached_mutex = Mutex.new()
	_refresh_cached_engine_mode()  # seed before thread starts reading it
	_thread_should_exit = false
	_thread = Thread.new()
	_thread.start(_thread_main)
	set_process(true)  # main-thread loop drains the tool-dispatch queue
	print_rich(
		"[color=cyan][GladeKit MCP Bridge][/color] "
		+ "listening on ws://%s:%d  (v%s, %d tools registered, thread-polled at %dHz)"
		% [BIND_ADDRESS, _port, VERSION, _registry.get_tool_count(), int(1000.0 / THREAD_POLL_SLEEP_MSEC)]
	)


func stop() -> void:
	if not _running:
		return
	_running = false
	set_process(false)
	_thread_should_exit = true
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	# Sockets are owned by the (now-stopped) worker thread — safe to tear down.
	for peer: WebSocketPeer in _peers:
		var state: int = peer.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN or state == WebSocketPeer.STATE_CONNECTING:
			peer.close(1001, "Bridge shutting down")
			peer.poll()
	_peers.clear()
	if _tcp_server != null:
		_tcp_server.stop()
		_tcp_server = null
	_pending_main_dispatches.clear()
	_pending_sends.clear()
	print_rich("[color=cyan][GladeKit MCP Bridge][/color] stopped")


# ── Main-thread tick: drain tool-dispatch queue + refresh cached state ───

func _process(_delta: float) -> void:
	if not _running:
		return
	_refresh_cached_engine_mode()
	_drain_pending_dispatches()


func _refresh_cached_engine_mode() -> void:
	var mode := "play" if EngineMode.is_play_mode() else "edit"
	_cached_mutex.lock()
	_cached_engine_mode = mode
	_cached_mutex.unlock()


func _drain_pending_dispatches() -> void:
	_pending_main_dispatches_mutex.lock()
	var dispatches: Array = _pending_main_dispatches.duplicate()
	_pending_main_dispatches.clear()
	_pending_main_dispatches_mutex.unlock()
	for entry: Dictionary in dispatches:
		var peer: WebSocketPeer = entry["peer"]
		var request: Dictionary = entry["request"]
		var request_id: String = entry["request_id"]
		var response := _main_dispatch_tool(request_id, request)
		_enqueue_send(peer, response)


func _main_dispatch_tool(request_id: String, request: Dictionary) -> Dictionary:
	var tool_name := str(request.get("toolName", ""))
	if tool_name.is_empty():
		return _make_error(request_id, "Missing 'toolName' field")
	var tool_instance = _registry.get_tool(tool_name)
	if tool_instance == null:
		return _make_error(request_id, "Unknown tool '%s'" % tool_name)

	# 'arguments' may arrive as a Dictionary or a JSON-encoded string.
	var raw_args = request.get("arguments", {})
	var args: Dictionary = {}
	if raw_args is Dictionary:
		args = raw_args
	elif raw_args is String:
		if (raw_args as String).is_empty():
			args = {}
		else:
			var parsed = JSON.parse_string(raw_args)
			if not (parsed is Dictionary):
				return _make_error(request_id, "'arguments' string is not a valid JSON object")
			args = parsed
	else:
		return _make_error(request_id, "'arguments' must be a JSON object or JSON-encoded string")

	if tool_instance.requires_edit_mode and EngineMode.is_play_mode():
		var msg := "Tool '%s' is edit-mode only; cannot run while Godot is playing the scene" % tool_name
		ErrorTracker.record(tool_name, msg, args)
		return _make_error(request_id, msg)

	# Read-only mode gate (set via ProjectSettings gladekit/read_only_mode
	# or env GLADEKIT_GODOT_READ_ONLY=1). Reads pass through; writes are
	# refused with a structured error so the agent can fall back to a
	# query plan.
	if not ReadOnlyGuard.is_allowed(tool_name):
		var ro_msg := "Tool '%s' is a write tool; bridge is in read-only mode" % tool_name
		ErrorTracker.record(tool_name, ro_msg, args)
		return _make_error(request_id, ro_msg)

	# Engine-version gate (e.g. ResourceUID tools are 4.4+ only). Tools
	# without a min_godot_version are unrestricted.
	if tool_instance.min_godot_version != "":
		var current_version := str(Engine.get_version_info().get("major", 0)) + "." + str(Engine.get_version_info().get("minor", 0)) + "." + str(Engine.get_version_info().get("patch", 0))
		if ToolUtils.compare_versions(current_version, tool_instance.min_godot_version) < 0:
			return _make_error(
				request_id,
				"Tool '%s' requires Godot %s or newer (running %s)" % [tool_name, tool_instance.min_godot_version, current_version]
			)

	# Args normalization: camelCase → snake_case in one place so every
	# tool sees a consistent shape (snake_case takes precedence on key
	# collisions). See ToolUtils.normalize_args for the rationale.
	args = ToolUtils.normalize_args(args)

	var result = tool_instance.execute(args)
	if not (result is Dictionary):
		var bad_msg := "Tool '%s' returned non-Dictionary" % tool_name
		ErrorTracker.record(tool_name, bad_msg, args)
		return _make_error(request_id, bad_msg)
	# Tool result already carries success/message/error — inject id and forward.
	# Also feed failures into the per-session ErrorTracker so the cloud loop
	# can see the recent failure pattern via the bridge's recent_errors
	# endpoint and avoid repeating mistakes on retry.
	if result.has("success") and not bool(result["success"]):
		var err_msg: String = str(result.get("error", result.get("message", "tool failed")))
		ErrorTracker.record(tool_name, err_msg, args)
	var response: Dictionary = {"id": request_id}
	for key in result:
		response[key] = result[key]
	return response


# ── Worker thread: accept, poll, send ────────────────────────────────────
# Owns _tcp_server, _peers, and the I/O loop. Touches main-thread state
# only via mutex-protected queues. Never calls EditorInterface or scene-tree
# APIs (those are not thread-safe).

func _thread_main() -> void:
	while not _thread_should_exit:
		_thread_accept()
		_thread_poll()
		_thread_send()
		OS.delay_msec(THREAD_POLL_SLEEP_MSEC)


func _thread_accept() -> void:
	if _tcp_server == null:
		return
	while _tcp_server.is_connection_available():
		var stream := _tcp_server.take_connection()
		if stream == null:
			break
		var ws := WebSocketPeer.new()
		var err := ws.accept_stream(stream)
		if err != OK:
			push_warning("[GladeKit MCP Bridge] accept_stream failed (error %d)" % err)
			continue
		_accept_log_count += 1
		_peers.append(ws)


func _thread_poll() -> void:
	var still_alive: Array[WebSocketPeer] = []
	for peer: WebSocketPeer in _peers:
		peer.poll()
		var state: int = peer.get_ready_state()
		match state:
			WebSocketPeer.STATE_OPEN:
				while peer.get_available_packet_count() > 0:
					var packet_bytes := peer.get_packet()
					_thread_handle_packet(peer, packet_bytes.get_string_from_utf8())
				still_alive.append(peer)
			WebSocketPeer.STATE_CONNECTING:
				still_alive.append(peer)
			_:
				# STATE_CLOSING / STATE_CLOSED — drop.
				pass
	_peers = still_alive


func _thread_handle_packet(peer: WebSocketPeer, packet_text: String) -> void:
	var parsed = JSON.parse_string(packet_text)
	if parsed == null or not (parsed is Dictionary):
		_enqueue_send(peer, _make_error("", "Request body is not a valid JSON object"))
		return
	var request: Dictionary = parsed
	var request_id := str(request.get("id", ""))
	var endpoint := str(request.get("endpoint", ""))
	if endpoint.is_empty():
		_enqueue_send(peer, _make_error(request_id, "Missing 'endpoint' field"))
		return
	match endpoint:
		"health":
			# Thread-safe metadata. Answer directly — fast path.
			_cached_mutex.lock()
			var mode := _cached_engine_mode
			_cached_mutex.unlock()
			_enqueue_send(peer, {
				"id": request_id,
				"success": true,
				"status": "ok",
				"bridgeVersion": VERSION,
				"bridgeKind": BRIDGE_KIND,
				"godotVersion": Engine.get_version_info().get("string", ""),
				"engineMode": mode,
				"toolCount": _registry.get_tool_count(),
			})
		"tools/list":
			_enqueue_send(peer, {
				"id": request_id,
				"success": true,
				"tools": _registry.get_tool_names(),
			})
		"diagnostics/recent_errors":
			# Returns the recent failure history for retry-context purposes.
			# Thread-safe: ErrorTracker uses an append-only static array;
			# returning a slice is fine without locking.
			var limit_raw = request.get("limit", 10)
			var limit: int = int(limit_raw) if (limit_raw is int or limit_raw is float) else 10
			_enqueue_send(peer, {
				"id": request_id,
				"success": true,
				"errors": ErrorTracker.recent(limit),
				"total": ErrorTracker.count(),
			})
		"tools/execute":
			# Marshal to main thread — tools touch the scene tree.
			_pending_main_dispatches_mutex.lock()
			_pending_main_dispatches.append({
				"peer": peer,
				"request": request,
				"request_id": request_id,
			})
			_pending_main_dispatches_mutex.unlock()
		_:
			_enqueue_send(peer, _make_error(request_id, "Unknown endpoint '%s'" % endpoint))


func _thread_send() -> void:
	_pending_sends_mutex.lock()
	var sends: Array = _pending_sends.duplicate()
	_pending_sends.clear()
	_pending_sends_mutex.unlock()
	for entry: Dictionary in sends:
		var peer: WebSocketPeer = entry["peer"]
		if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
			continue
		var json := JSON.stringify(entry["response"])
		var err := peer.send_text(json)
		if err != OK:
			push_warning("[GladeKit MCP Bridge] send_text failed (error %d)" % err)


# ── Cross-thread helpers ─────────────────────────────────────────────────

func _enqueue_send(peer: WebSocketPeer, response: Dictionary) -> void:
	_pending_sends_mutex.lock()
	_pending_sends.append({"peer": peer, "response": response})
	_pending_sends_mutex.unlock()


func _make_error(request_id: String, message: String) -> Dictionary:
	return {
		"id": request_id,
		"success": false,
		"error": message,
		"message": message,
	}


# ── Version + port resolution + bind-failure UX ──────────────────────────

# Read the bridge version from plugin.cfg at startup. Single source of truth:
# the same line the Godot plugin system reads to display "v0.4.0" in the
# Project Settings → Plugins UI is what we return over the wire. Removes the
# whole class of "hardcoded const drifted from plugin.cfg" bugs.
func _read_version() -> String:
	var cfg := ConfigFile.new()
	var err := cfg.load(PLUGIN_CFG_PATH)
	if err != OK:
		push_warning(
			"[GladeKit MCP Bridge] Could not load plugin.cfg (err %d). " % err
			+ "Reporting bridgeVersion as 'unknown'. Check that the addon is "
			+ "installed at %s." % PLUGIN_CFG_PATH
		)
		return "unknown"
	var v = cfg.get_value("plugin", "version", "unknown")
	return str(v) if v != null else "unknown"


func _resolve_port() -> int:
	var override: String = OS.get_environment("GLADEKIT_GODOT_BRIDGE_PORT")
	if not override.is_empty() and override.is_valid_int():
		var p := int(override)
		if p > 0 and p < 65536:
			return p
	return DEFAULT_PORT


func _handle_bind_failure(err: int) -> void:
	var lines: Array = []
	if err == ERR_ALREADY_IN_USE:
		lines.append("Port %d is already in use." % _port)
	else:
		lines.append("Could not bind to port %d (Godot error %d)." % [_port, err])
	lines.append("")
	lines.append("Fix: set the GLADEKIT_GODOT_BRIDGE_PORT environment variable to a free port")
	lines.append("and restart the Godot editor. Example: GLADEKIT_GODOT_BRIDGE_PORT=8868")
	lines.append("")
	lines.append("Note: if you also run the GladeKit Unity bridge on this machine, that uses")
	lines.append("port 8765 — Godot uses 8766 by default, so the two should not collide.")
	var msg := "[GladeKit MCP Bridge] " + "\n  ".join(lines)
	push_error(msg)
	printerr(msg)
