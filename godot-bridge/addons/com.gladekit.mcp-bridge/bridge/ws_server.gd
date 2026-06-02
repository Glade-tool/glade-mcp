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

const ToolRegistry   = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd")
const ToolUtils      = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const EngineMode     = preload("res://addons/com.gladekit.mcp-bridge/bridge/engine_mode.gd")
const ReadOnlyGuard  = preload("res://addons/com.gladekit.mcp-bridge/services/read_only_guard.gd")
const ErrorTracker   = preload("res://addons/com.gladekit.mcp-bridge/services/error_tracker.gd")
const BackupManager  = preload("res://addons/com.gladekit.mcp-bridge/services/backup_manager.gd")

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
		var endpoint: String = str(request.get("endpoint", ""))
		var response: Dictionary
		if endpoint == "context/gather":
			response = _main_dispatch_context_gather(request_id, request)
		elif endpoint == "backup/file":
			response = _main_dispatch_backup_file(request_id, request)
		elif endpoint == "backup/check_exists":
			response = _main_dispatch_backup_check_exists(request_id, request)
		elif endpoint == "turn/revert":
			response = _main_dispatch_turn_revert(request_id, request)
		elif endpoint == "turn/accept":
			response = _main_dispatch_turn_accept(request_id, request)
		else:
			response = _main_dispatch_tool(request_id, request)
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


# Aggregate the bridge's three first-turn signals (project metadata, scene
# tree, recent failure history) into one round-trip. Used by clients that
# would otherwise spend 2-3 separate tools/execute calls to orient the
# agent on each session's first turn. Returns success-shaped even when
# individual sub-fetches fail — the caller treats this as best-effort
# orientation, not a hard precondition.
#
# Args (all optional):
#   project_response_format: "concise" (default) | "detailed" — passed
#       through to get_project_info. Detailed mode adds bounded file
#       listings and the input map.
#   scene_max_depth: int — passed through to get_scene_tree as max_depth.
#       Defaults to the tool's own default (50) when omitted.
#   errors_limit: int — how many recent ErrorTracker entries to include.
#       Defaults to 10.
#
# Response payload:
#   project:     Dictionary — get_project_info's `project` payload, or
#                {} on failure with an `errors.project` entry.
#   scene_tree:  Dictionary — get_scene_tree's payload (tree, tree_text,
#                scene_path, node_count), or null on failure.
#   recent_errors: Array — most-recent-first list of {tool, message, args_summary}.
#   errors:      Dictionary — sub-fetch failure messages keyed by source
#                ("project" | "scene_tree"). Absent when all three succeed.
func _main_dispatch_context_gather(request_id: String, request: Dictionary) -> Dictionary:
	var project_format: String = str(request.get("project_response_format", "concise"))
	var scene_max_depth_raw = request.get("scene_max_depth", null)
	var errors_limit_raw = request.get("errors_limit", 10)
	var errors_limit: int = int(errors_limit_raw) if (errors_limit_raw is int or errors_limit_raw is float) else 10

	var response: Dictionary = {
		"id": request_id,
		"success": true,
		"project": {},
		"scene_tree": null,
		"recent_errors": [],
	}
	var sub_errors: Dictionary = {}

	# Project info — reuse the existing tool's execute() rather than
	# re-implementing the file walk. Tool returns its own success/error envelope.
	var project_tool = _registry.get_tool("get_project_info")
	if project_tool != null:
		var project_result = project_tool.execute({"response_format": project_format})
		if project_result is Dictionary and project_result.get("success", false):
			response["project"] = project_result.get("project", {})
		else:
			sub_errors["project"] = str(project_result.get("error", project_result.get("message", "get_project_info failed")))
	else:
		sub_errors["project"] = "get_project_info tool not registered"

	# Scene tree — same pattern. tree + tree_text + scene_path + node_count.
	var scene_args: Dictionary = {}
	if scene_max_depth_raw != null:
		scene_args["max_depth"] = scene_max_depth_raw
	var scene_tool = _registry.get_tool("get_scene_tree")
	if scene_tool != null:
		var scene_result = scene_tool.execute(scene_args)
		if scene_result is Dictionary and scene_result.get("success", false):
			response["scene_tree"] = {
				"tree":       scene_result.get("tree"),
				"tree_text":  scene_result.get("tree_text", ""),
				"scene_path": scene_result.get("scene_path", ""),
				"node_count": scene_result.get("node_count", 0),
			}
		else:
			sub_errors["scene_tree"] = str(scene_result.get("error", scene_result.get("message", "get_scene_tree failed")))
	else:
		sub_errors["scene_tree"] = "get_scene_tree tool not registered"

	# Recent errors — already thread-safe (append-only static array). Mirrors
	# the diagnostics/recent_errors endpoint's slice, so clients can build a
	# retry-context prompt without a second round-trip.
	if errors_limit > 0:
		response["recent_errors"] = ErrorTracker.recent(errors_limit)

	if not sub_errors.is_empty():
		response["errors"] = sub_errors

	return response


# ── File-level revert/backup endpoints ────────────────────────────────────
# A four-endpoint set that lets a client drive a per-turn undo flow:
#
#   backup/file          take a pre-mutation snapshot, returns abs path
#   backup/check_exists  prune turn entries whose snapshots are GC'd
#   turn/revert          restore (or delete) per-change file outcomes
#   turn/accept          tear down a turn's backup subtree
#
# Implementations live on BackupManager — these handlers just unmarshal
# arguments and roll up per-change outcomes. Scene-tree (node) mutations
# are not yet revertible: turn/revert accepts a `gameObjectChanges`
# array for protocol symmetry but reports 0/0 for those counts and
# annotates the message. A follow-up will add PackedScene-based node-state
# backups to close that gap.
func _main_dispatch_backup_file(request_id: String, request: Dictionary) -> Dictionary:
	var file_path: String = str(request.get("filePath", ""))
	if file_path.is_empty():
		return _make_error(request_id, "filePath is required")
	if not (file_path.begins_with("res://") or file_path.begins_with("user://")):
		# Lift Unity-style "Assets/Player.cs" to a res:// URI. Same trim the
		# bridge tools' parse_path_arg helper does — the renderer's wire
		# format is engine-agnostic, the bridge normalizes here.
		if file_path.begins_with("/"):
			file_path = file_path.substr(1)
		file_path = "res://" + file_path
	var turn_id: String = str(request.get("turnId", ""))
	# If the source file doesn't exist there's nothing to back up — a
	# create_*-style tool is about to write it for the first time. Return
	# success with no backupPath so the renderer records a "file_created"
	# change (revert path will delete the file instead of restoring).
	if not FileAccess.file_exists(file_path):
		return {
			"id": request_id,
			"success": true,
			"backupPath": "",
			"note": "source did not exist at backup time (likely a create-style mutation)",
		}
	var abs_backup_path := BackupManager.backup_file(file_path, turn_id)
	if abs_backup_path.is_empty():
		return _make_error(request_id, "backup_file returned empty path for '%s'" % file_path)
	return {
		"id": request_id,
		"success": true,
		"backupPath": abs_backup_path,
	}


func _main_dispatch_backup_check_exists(request_id: String, request: Dictionary) -> Dictionary:
	var raw = request.get("paths", [])
	if not (raw is Array):
		return _make_error(request_id, "paths must be an array")
	var existing: Array = []
	for entry in raw:
		var p: String = str(entry)
		if BackupManager.path_exists(p):
			existing.append(p)
	return {
		"id": request_id,
		"success": true,
		"existingPaths": existing,
	}


func _main_dispatch_turn_revert(request_id: String, request: Dictionary) -> Dictionary:
	var turn_id: String = str(request.get("turnId", ""))
	if turn_id.is_empty():
		return _make_error(request_id, "turnId is required")
	var raw_file_changes = request.get("fileChanges", [])
	if not (raw_file_changes is Array):
		return _make_error(request_id, "fileChanges must be an array")
	var files_restored: int = 0
	var files_deleted: int = 0
	var errors: Array = []
	for entry in raw_file_changes:
		if not (entry is Dictionary):
			errors.append({"error": "fileChanges entry was not a Dictionary"})
			continue
		var change: Dictionary = entry
		var change_type: String = str(change.get("changeType", "")).to_lower()
		var file_path: String = str(change.get("filePath", ""))
		var backup_path: String = str(change.get("backupPath", ""))
		if file_path.is_empty():
			errors.append({"error": "fileChanges entry missing filePath", "change": change})
			continue
		if not (file_path.begins_with("res://") or file_path.begins_with("user://")):
			if file_path.begins_with("/"):
				file_path = file_path.substr(1)
			file_path = "res://" + file_path
		match change_type:
			"created":
				# Undo a creation: delete the file. No backup to consult.
				var del := BackupManager.delete_file(file_path)
				if del.get("success", false):
					if del.get("deleted", false):
						files_deleted += 1
				else:
					errors.append({"filePath": file_path, "changeType": change_type, "error": del.get("error", "delete failed")})
			"modified", "deleted":
				if backup_path.is_empty():
					errors.append({"filePath": file_path, "changeType": change_type, "error": "backupPath required for %s revert" % change_type})
					continue
				var res := BackupManager.restore_file(backup_path, file_path)
				if res.get("success", false):
					files_restored += 1
				else:
					errors.append({"filePath": file_path, "changeType": change_type, "error": res.get("error", "restore failed")})
			_:
				errors.append({"filePath": file_path, "changeType": change_type, "error": "unknown changeType"})

	# Tell the editor's filesystem to rescan so the rewound state shows up
	# without the user manually triggering Project → Reload Current Project.
	# Best-effort: a failed scan doesn't fail the revert.
	var fs = EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.scan()

	# Scene-tree mutations aren't yet revertible on Godot. The renderer
	# can send `gameObjectChanges` for symmetry with the Unity contract;
	# we accept the field and report 0/0. A follow-up PR will add
	# PackedScene-based node-state backups.
	var go_changes_raw = request.get("gameObjectChanges", [])
	var go_count: int = (go_changes_raw as Array).size() if (go_changes_raw is Array) else 0
	var message: String
	if go_count > 0:
		message = "Reverted %d file change(s); scene-tree changes (%d) are not yet revertible on Godot." % [files_restored + files_deleted, go_count]
	else:
		message = "Reverted %d file change(s)." % (files_restored + files_deleted)

	var response: Dictionary = {
		"id": request_id,
		"success": errors.is_empty(),
		"message": message,
		"filesRestored": files_restored,
		"filesDeleted": files_deleted,
		"gameObjectsRestored": 0,
		"gameObjectsDeleted": 0,
	}
	if not errors.is_empty():
		response["errors"] = errors
		response["error"] = "%d change(s) failed to revert" % errors.size()
	return response


func _main_dispatch_turn_accept(request_id: String, request: Dictionary) -> Dictionary:
	var turn_id: String = str(request.get("turnId", ""))
	if turn_id.is_empty():
		return _make_error(request_id, "turnId is required")
	var removed: int = BackupManager.delete_turn(turn_id)
	return {
		"id": request_id,
		"success": true,
		"message": "Accepted turn %s (removed %d backup file(s))" % [turn_id, removed],
		"backupsRemoved": removed,
	}


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
		"context/gather":
			# One-shot project orientation snapshot for clients (Electron's
			# pre-prompt context, primarily). Aggregates get_project_info +
			# get_scene_tree + recent_errors so the agent doesn't burn
			# 2-3 round-trips on every Godot session's first turn.
			# Scene-tree access requires the main thread.
			_pending_main_dispatches_mutex.lock()
			_pending_main_dispatches.append({
				"peer": peer,
				"request": request,
				"request_id": request_id,
			})
			_pending_main_dispatches_mutex.unlock()
		"backup/file", "backup/check_exists", "turn/revert", "turn/accept":
			# File-level revert/backup endpoints. Routed through the main
			# thread for two reasons: (a) FileAccess + DirAccess operations
			# are safer on the editor's main thread, and (b) turn/revert
			# refreshes EditorInterface.get_resource_filesystem() after the
			# restore so the editor immediately reflects the rewound state —
			# that call is main-thread-only. These endpoints don't touch
			# the scene tree, so latency is dominated by disk I/O.
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
