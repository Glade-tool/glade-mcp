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

# Main-thread stall watchdog. tools/execute (and the other main-thread
# endpoints) wait on the editor's main thread; if a modal dialog or a long
# synchronous operation blocks the editor, queued dispatches would otherwise
# sit until every client rides out its own timeout with an opaque error —
# and every FOLLOW-UP call piles up behind them, so the whole bridge looks
# dead. The worker thread expires dispatches older than this and answers
# with a structured "editor main thread stalled" error that names the cause
# and how to clear it. Keep this below typical client per-call timeouts
# (the gladekit-mcp server uses 30s) so clients receive the diagnostic
# instead of their own generic timeout.
const MAIN_DISPATCH_STALL_TIMEOUT_MSEC := 25_000

# Hard ceiling for an async tool (e.g. import_asset) from the moment its
# execute() returns an "async_pending" marker to the moment poll() yields a
# final result. Unlike the stall watchdog above — which guards work still
# QUEUED on the main thread — this guards work already IN FLIGHT on a worker
# thread (a download that hangs). Set above the downloader's own 60s timeout so
# the tool's own error surfaces first; this is the backstop if the tool itself
# wedges. NOTE: pure-MCP clients typically use a ~30s per-call timeout, so an
# async job that runs longer than that is answered to a client that has already
# given up — fine for small CC0 packs (sub-second to a few seconds), but the
# reason large/slow downloads are out of scope for v1.
const ASYNC_DISPATCH_TIMEOUT_MSEC := 90_000

# WebSocketPeer defaults to 64KB in/out buffers. Tool payloads routinely
# exceed that: get_script_content allows max_lines=5000 (~200KB+),
# get_scene_tree response_format="both" on a large scene, and context/gather
# aggregates several of those. An oversized outbound frame makes send_text
# fail (client hangs to timeout); an oversized inbound frame (e.g.
# create_script with a large content arg) never arrives. Sized for the
# largest realistic payloads; allocated per peer, and peer count is
# effectively 1-2, so the memory cost is bounded.
const WS_INBOUND_BUFFER_SIZE := 4 * 1024 * 1024   # 4 MiB
const WS_OUTBOUND_BUFFER_SIZE := 8 * 1024 * 1024  # 8 MiB

# Unknown-tool typo recovery — when tools/execute fails to resolve a name,
# surface up to MAX nearest tool names within DISTANCE_THRESHOLD edits so the
# agent can self-correct on the next turn instead of flailing. Threshold of 4
# catches single character drops/swaps in 12–20 char tool names without
# spamming unrelated suggestions on a genuinely unknown query.
const UNKNOWN_TOOL_SUGGESTION_MAX := 3
const UNKNOWN_TOOL_SUGGESTION_DISTANCE_THRESHOLD := 4

const ToolRegistry      = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd")
const ToolUtils         = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const EngineMode        = preload("res://addons/com.gladekit.mcp-bridge/bridge/engine_mode.gd")
const ReadOnlyGuard     = preload("res://addons/com.gladekit.mcp-bridge/services/read_only_guard.gd")
const ErrorTracker      = preload("res://addons/com.gladekit.mcp-bridge/services/error_tracker.gd")
const BackupManager     = preload("res://addons/com.gladekit.mcp-bridge/services/backup_manager.gd")
const SessionTracker    = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")
const RuntimeLogStream  = preload("res://addons/com.gladekit.mcp-bridge/services/runtime_log_stream.gd")
const PlaySessionManager = preload("res://addons/com.gladekit.mcp-bridge/services/play_session_manager.gd")

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

# Async tool dispatches awaiting completion. Main-thread-only — appended when a
# tool's execute() returns an "async_pending" marker, drained each _process
# tick by polling the tool. No mutex: only the main thread touches it.
# Entry shape: { peer, request_id, tool, tool_name, started_msec }.
var _pending_async: Array = []

# Cached engine mode, refreshed by main thread, read by worker thread.
var _cached_engine_mode: String = "edit"
var _cached_mutex: Mutex = null

# Project identity, seeded on the main thread in start() before the worker
# spawns (same contract as VERSION — written once, then read-only, so the
# worker thread can read them on every health request without a mutex).
# Reported in the health payload so clients can locate this project on disk
# (e.g. to update the addon files in place) without guessing from scans.
var _project_name: String = ""
var _project_path: String = ""

# Main-thread heartbeat: last Time.get_ticks_msec() at which the main thread
# made progress (each _process tick, and after each dispatched tool inside a
# batch). Written by the main thread, read by the worker thread, guarded by
# _cached_mutex. Drives the stall watchdog's diagnostics and the health
# endpoint's mainThreadStalledMsec field.
var _last_main_tick_msec: int = 0

# ── Diagnostics ──────────────────────────────────────────────────────────
var _accept_log_count: int = 0


# ── Lifecycle (main thread) ──────────────────────────────────────────────

func start() -> void:
	if _running:
		return
	# Resolve VERSION before anything reads it. Must happen before _thread
	# spawns (the worker thread reads VERSION on every health request).
	VERSION = _read_version()
	_project_name = str(ProjectSettings.get_setting("application/config/name", ""))
	_project_path = ProjectSettings.globalize_path("res://").trim_suffix("/")
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
	_touch_main_heartbeat()  # seed so the watchdog doesn't see a phantom stall at boot
	# Reap any orphaned play-session PIDs from a previous plugin instance
	# (hot-reload survival — see PlaySessionManager.reap_orphans comment).
	# Runs synchronously on the main thread before we start accepting tool
	# calls so new run_project calls can't race with the cleanup.
	var reaped: Array = PlaySessionManager.reap_orphans()
	if not reaped.is_empty():
		var killed_count: int = 0
		for entry in reaped:
			if bool(entry.get("killed", false)):
				killed_count += 1
		print_rich(
			"[color=yellow][GladeKit MCP Bridge][/color] "
			+ _format_reap_message(reaped.size(), killed_count)
		)
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
	_pending_async.clear()
	print_rich("[color=cyan][GladeKit MCP Bridge][/color] stopped")


# ── Main-thread tick: drain tool-dispatch queue + refresh cached state ───

func _process(_delta: float) -> void:
	if not _running:
		return
	_touch_main_heartbeat()
	_refresh_cached_engine_mode()
	_drain_pending_dispatches()
	_drain_async_dispatches()
	# Drain any live play-session pipes every tick. A headless child (run_project
	# / run_gameplay_probe) writes stdout/stderr into an OS pipe of bounded size
	# (small on Windows); if the bridge only drained on demand, a child that
	# spams stderr — exactly what a broken input action does, printing an
	# InputMap error every frame — fills the pipe and BLOCKS on write() on its
	# own main thread, so it never reaches quit() and the run hangs. Draining
	# each tick keeps the pipe clear so the child runs to completion, and makes
	# freshly-printed output (e.g. the gameplay-probe report) visible to the
	# next get_debug_output without waiting for a pipe-sized backlog to flush.
	if PlaySessionManager.has_active_sessions():
		PlaySessionManager.tick_all_sessions()


func _refresh_cached_engine_mode() -> void:
	var mode := "play" if EngineMode.is_play_mode() else "edit"
	_cached_mutex.lock()
	_cached_engine_mode = mode
	_cached_mutex.unlock()


func _touch_main_heartbeat() -> void:
	_cached_mutex.lock()
	_last_main_tick_msec = Time.get_ticks_msec()
	_cached_mutex.unlock()


func _drain_pending_dispatches() -> void:
	# Pop one entry at a time instead of bulk-draining the whole queue:
	# entries still waiting stay visible to the worker thread's stall
	# watchdog while an earlier tool executes, and the heartbeat refresh
	# after each entry tells the watchdog "busy, not wedged" during a long
	# multi-tool batch.
	while true:
		_pending_main_dispatches_mutex.lock()
		if _pending_main_dispatches.is_empty():
			_pending_main_dispatches_mutex.unlock()
			return
		var entry: Dictionary = _pending_main_dispatches.pop_front()
		_pending_main_dispatches_mutex.unlock()
		var peer: WebSocketPeer = entry["peer"]
		var request: Dictionary = entry["request"]
		var request_id: String = entry["request_id"]
		var endpoint: String = str(request.get("endpoint", ""))
		var response: Dictionary
		if endpoint == "context/gather":
			response = _main_dispatch_context_gather(request_id, request)
		elif endpoint == "backup/file":
			response = _main_dispatch_backup_file(request_id, request)
		elif endpoint == "backup/node":
			response = _main_dispatch_backup_node(request_id, request)
		elif endpoint == "backup/check_exists":
			response = _main_dispatch_backup_check_exists(request_id, request)
		elif endpoint == "turn/revert":
			response = _main_dispatch_turn_revert(request_id, request)
		elif endpoint == "turn/accept":
			response = _main_dispatch_turn_accept(request_id, request)
		else:
			response = _main_dispatch_tool(request_id, request, peer)
		# An empty response is the sentinel for "deferred": the tool started
		# async work and registered itself in _pending_async; its real response
		# is sent later by _drain_async_dispatches. Don't send anything now.
		if not response.is_empty():
			_enqueue_send(peer, response)
		_touch_main_heartbeat()


# Poll in-flight async tool dispatches once per tick. Each tool's poll()
# returns {} while still running, or its final result Dictionary when done.
# Finished tools have their response sent and are removed; a tool that exceeds
# ASYNC_DISPATCH_TIMEOUT_MSEC is answered with a structured timeout error so the
# client never hangs on a wedged worker.
func _drain_async_dispatches() -> void:
	if _pending_async.is_empty():
		return
	var now := Time.get_ticks_msec()
	var still_pending: Array = []
	for entry: Dictionary in _pending_async:
		var tool = entry["tool"]
		var tool_name: String = str(entry["tool_name"])
		var result = tool.poll()
		if result == null or not (result is Dictionary) or (result as Dictionary).is_empty():
			# Still running — unless it has blown the hard ceiling.
			if now - int(entry["started_msec"]) > ASYNC_DISPATCH_TIMEOUT_MSEC:
				var to_msg := (
					"Async tool '%s' did not finish within %ds and was abandoned. "
					+ "The download may have stalled; retry, and check your network."
				) % [tool_name, ASYNC_DISPATCH_TIMEOUT_MSEC / 1000]
				ErrorTracker.record(tool_name, to_msg, {})
				_enqueue_send(entry["peer"], _make_error(str(entry["request_id"]), to_msg))
			else:
				still_pending.append(entry)
			continue
		# Finished — forward the final result.
		var final: Dictionary = result
		if not final.has("success"):
			final = _make_error(str(entry["request_id"]), "Async tool '%s' returned a result missing 'success'" % tool_name)
		if not bool(final.get("success", false)):
			ErrorTracker.record(tool_name, str(final.get("error", final.get("message", "async tool failed"))), {})
		var response: Dictionary = {"id": entry["request_id"]}
		for key in final:
			response[key] = final[key]
		_enqueue_send(entry["peer"], response)
	_pending_async = still_pending


func _main_dispatch_tool(request_id: String, request: Dictionary, peer: WebSocketPeer) -> Dictionary:
	var tool_name := str(request.get("toolName", ""))
	if tool_name.is_empty():
		return _make_error(request_id, "Missing 'toolName' field")
	var tool_instance = _registry.get_tool(tool_name)
	if tool_instance == null:
		# Surface levenshtein-ranked neighbors so the agent can recover from a
		# typo'd tool name on the next turn without a round-trip through
		# tools/list. Matches the recovery pattern already used inside
		# create_resource (unknown class names) and connect_signal (unknown
		# signal names).
		var response := _make_error(request_id, "Unknown tool '%s'" % tool_name)
		var suggestions := _suggest_tool_names(tool_name)
		if not suggestions.is_empty():
			response["possible_solutions"] = suggestions
		return response

	# 'arguments' may arrive as a Dictionary or a JSON-encoded string.
	var raw_args = request.get("arguments", {})
	var args: Dictionary = {}
	if raw_args is Dictionary:
		args = raw_args
	elif raw_args is String:
		if (raw_args as String).is_empty():
			args = {}
		else:
			# Instance parse — silent on malformed input (see
			# _thread_handle_packet for why the static helper isn't used).
			var args_json := JSON.new()
			if args_json.parse(raw_args) != OK or not (args_json.data is Dictionary):
				return _make_error(request_id, "'arguments' string is not a valid JSON object")
			args = args_json.data
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

	# Scope the per-call "scripts written this call" buffer to THIS execute() so
	# the dispatcher can report freshly-written scripts (incl. those template/
	# scaffolder tools embed internally) back to the client for diff/revert.
	SessionTracker.begin_call()

	# Snapshot the edited scene's node set before the tool runs, so we can report
	# which nodes it CREATED back to the client for revert — even template/
	# scaffolder tools that build a whole subtree internally (their node paths
	# never appear in the args, and they're not in the client's known-node-tool
	# list). Only for mutating tools (requires_edit_mode) with an open scene;
	# read tools and headless contexts skip the walk.
	var scene_root_before: Node = ToolUtils.get_edited_scene_root_safe()
	var track_nodes: bool = tool_instance.requires_edit_mode and scene_root_before != null
	var nodes_before: Dictionary = {}
	if track_nodes:
		_collect_instance_ids(scene_root_before, nodes_before)

	# GDScript has no try/catch, so we can't wrap execute() — but a runtime
	# error inside a tool halts the call and returns null. The is-Dictionary
	# check below catches that case (null is not Dictionary), plus the
	# legitimate "tool returned the wrong shape" misuse. We surface a more
	# specific diagnostic for null than for a wrong-typed Dict so the agent
	# can distinguish "tool crashed" from "tool author returned the wrong
	# value." Both also push_error to the editor output panel so the user
	# can correlate with whatever stack trace Godot already logged.
	var result = tool_instance.execute(args)
	if result == null:
		var crash_msg := (
			"Tool '%s' crashed during execute() — the call halted and "
			+ "returned null. Check the Godot Output panel for the underlying "
			+ "stack trace (push_error / nil deref / etc.)."
		) % tool_name
		push_error("[GladeKit MCP Bridge] " + crash_msg)
		ErrorTracker.record(tool_name, crash_msg, args)
		return _make_error(request_id, crash_msg)
	if not (result is Dictionary):
		var bad_msg := "Tool '%s' returned %s; expected Dictionary" % [tool_name, typeof(result)]
		push_error("[GladeKit MCP Bridge] " + bad_msg)
		ErrorTracker.record(tool_name, bad_msg, args)
		return _make_error(request_id, bad_msg)
	if not (result as Dictionary).has("success"):
		var shape_msg := "Tool '%s' returned a Dictionary missing the required 'success' field" % tool_name
		push_error("[GladeKit MCP Bridge] " + shape_msg)
		ErrorTracker.record(tool_name, shape_msg, args)
		return _make_error(request_id, shape_msg)

	# Attach the SCRIPTS this call freshly wrote (drained from the per-call
	# buffer) so clients can show a script diff + revert them — even for
	# template/scaffolder tools whose script body never appears in the args. A
	# tool that already reports its own `written_scripts` is left untouched.
	# Filtered to script files so the field stays honest: some scaffolders also
	# mark a generated .tscn as created (e.g. a menu scene), which isn't a
	# diffable script.
	var recent_writes: Array = SessionTracker.take_recent_writes()
	var written_scripts: Array = []
	for w in recent_writes:
		var lower := str(w).to_lower()
		if lower.ends_with(".gd") or lower.ends_with(".cs"):
			written_scripts.append(w)
	if not written_scripts.is_empty() and not (result as Dictionary).has("written_scripts"):
		(result as Dictionary)["written_scripts"] = written_scripts

	# Attach the top-level NODES this call created (scene-tree diff against the
	# pre-execute snapshot) so clients can revert them — even template/scaffolder
	# tools that build a subtree internally. Only top-level new nodes are
	# reported: deleting one removes its new descendants, so children are
	# redundant. Skipped when the scene root was swapped (open_scene /
	# create_scene), where "every node is new" would be a false positive. A tool
	# that already reports its own `created_nodes` is left untouched.
	if track_nodes and not (result as Dictionary).has("created_nodes"):
		var scene_root_after: Node = ToolUtils.get_edited_scene_root_safe()
		if scene_root_after != null and is_instance_valid(scene_root_before) and scene_root_after == scene_root_before:
			var new_nodes: Array = []
			_collect_new_top_level_nodes(scene_root_after, nodes_before, new_nodes)
			var created_nodes: Array = []
			for n in new_nodes:
				var rel := ToolUtils.node_relative_path(n)
				if rel != "":
					created_nodes.append(rel)
			if not created_nodes.is_empty():
				(result as Dictionary)["created_nodes"] = created_nodes

	# Async tools: execute() kicked off a worker thread and returned an
	# "async_pending" marker rather than the final answer. Register the tool to
	# be polled each tick (see _drain_async_dispatches) and return the empty
	# sentinel so the caller sends nothing now. The single real response is sent
	# when poll() yields a final result.
	if bool((result as Dictionary).get("async_pending", false)):
		_pending_async.append({
			"peer": peer,
			"request_id": request_id,
			"tool": tool_instance,
			"tool_name": tool_name,
			"started_msec": Time.get_ticks_msec(),
		})
		return {}

	# Tool result already carries success/message/error — inject id and forward.
	# Also feed failures into the per-session ErrorTracker so callers can read
	# the recent failure pattern via the bridge's recent_errors endpoint and
	# avoid repeating mistakes on retry.
	if result.has("success") and not bool(result["success"]):
		var err_msg: String = str(result.get("error", result.get("message", "tool failed")))
		ErrorTracker.record(tool_name, err_msg, args)
	var response: Dictionary = {"id": request_id}
	for key in result:
		response[key] = result[key]
	return response


# Recursively record every descendant's instance id into `out` (a set). Used to
# snapshot the edited scene before a tool runs so post-run we can tell which
# nodes are new. Instance ids (not paths) so a rename/move during the call
# doesn't masquerade as a create.
static func _collect_instance_ids(node: Node, out: Dictionary) -> void:
	for child in node.get_children():
		out[child.get_instance_id()] = true
		_collect_instance_ids(child, out)


# Walk the post-run tree and append every TOP-LEVEL new Node (one absent from
# `before` whose parent was already present) to `out`. A new node nested under
# another new node is skipped — reverting the top-level node deletes the whole
# new subtree, so listing children would be redundant (and would make revert
# try to delete already-deleted nodes). Collects Node refs (not paths) so the
# diff logic is unit-testable without an editor; the caller maps to paths.
static func _collect_new_top_level_nodes(node: Node, before: Dictionary, out: Array) -> void:
	for child in node.get_children():
		if not before.has(child.get_instance_id()):
			out.append(child)
			# Do NOT recurse: the entire subtree under a new node is new.
		else:
			_collect_new_top_level_nodes(child, before, out)


# Aggregate the bridge's three first-turn signals (project metadata, scene
# tree, recent failure history) into one round-trip. Used by clients that
# would otherwise spend 2-3 separate tools/execute calls to orient the
# agent on each session's first turn.
#
# `success` reflects whether ALL sub-fetches succeeded (atomic shape). When
# any sub-fetch fails, `success=false` AND the per-source error is recorded
# in `errors`, so clients that only check `success` won't silently consume
# partial context as if it were complete. Callers that want the
# best-effort partial payload can still inspect `project`, `scene_tree`,
# `recent_errors`, and `runtime_events` regardless of `success`.
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
#   project:        Dictionary — get_project_info's `project` payload, or
#                   {} on failure with an `errors.project` entry.
#   scene_tree:     Dictionary — get_scene_tree's payload (tree, tree_text,
#                   scene_path, node_count), or null on failure.
#   recent_errors:  Array — most-recent-first list of bridge tool-dispatch
#                   failures: {tool, message, args_summary}.
#   runtime_events: Array — most-recent-first list of structured runtime
#                   errors parsed from play-session stderr: {cursor, message,
#                   stack_trace, log_type, timestamp, fingerprint}. Empty
#                   when no play sessions have run this editor session.
#   errors:         Dictionary — sub-fetch failure messages keyed by source
#                   ("project" | "scene_tree"). Absent when all three succeed.
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
		"runtime_events": [],
	}
	var sub_errors: Dictionary = {}

	# Project info — reuse the existing tool's execute() rather than
	# re-implementing the file walk. Tool returns its own success/error envelope.
	# A null return indicates a crashed sub-tool (GDScript halt + nil return);
	# treat the same as a structured failure so context/gather still answers.
	var project_tool = _registry.get_tool("get_project_info")
	if project_tool != null:
		var project_result = project_tool.execute({"response_format": project_format})
		if project_result == null:
			sub_errors["project"] = "get_project_info crashed (returned null)"
		elif project_result is Dictionary and project_result.get("success", false):
			response["project"] = project_result.get("project", {})
		else:
			sub_errors["project"] = str(project_result.get("error", project_result.get("message", "get_project_info failed")))
	else:
		sub_errors["project"] = "get_project_info tool not registered"

	# Scene tree — same pattern. tree + tree_text + scene_path + node_count.
	# Pin response_format="both" so this aggregating endpoint keeps returning
	# both shapes even if get_scene_tree's default ever changes.
	var scene_args: Dictionary = {"response_format": "both"}
	if scene_max_depth_raw != null:
		scene_args["max_depth"] = scene_max_depth_raw
	var scene_tool = _registry.get_tool("get_scene_tree")
	if scene_tool != null:
		var scene_result = scene_tool.execute(scene_args)
		if scene_result == null:
			sub_errors["scene_tree"] = "get_scene_tree crashed (returned null)"
		elif scene_result is Dictionary and scene_result.get("success", false):
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
		# Runtime events — structured play-session errors from RuntimeLogStream.
		# Pump active session pipes first so any output that landed since the
		# last drain is reflected. Walk the tail of the ring for the most-recent
		# `errors_limit` entries; the order matches the agent-facing convention
		# (most-recent first) used by recent_errors above.
		PlaySessionManager.tick_all_sessions()
		var all_runtime: Array = RuntimeLogStream.get_events_since_cursor(0, RuntimeLogStream.MAX_ENTRIES)
		var runtime_tail: Array = all_runtime
		if all_runtime.size() > errors_limit:
			runtime_tail = all_runtime.slice(all_runtime.size() - errors_limit)
		runtime_tail.reverse()  # most-recent first
		response["runtime_events"] = runtime_tail

	if not sub_errors.is_empty():
		response["success"] = false
		response["errors"] = sub_errors
		# Bake the failure summary into message so chat-only readers don't
		# miss it. Without this, an agent reading "context gathered" assumes
		# the payload is complete and proceeds with stale assumptions.
		var failed_sources: Array = []
		for source in sub_errors.keys():
			failed_sources.append(str(source))
		response["message"] = "context/gather: %d of N sub-fetches failed: %s" % [
			sub_errors.size(), ", ".join(failed_sources),
		]
		response["error"] = response["message"]

	return response


# ── Revert/backup endpoints ───────────────────────────────────────────────
# A five-endpoint set that lets a client drive a per-turn undo flow:
#
#   backup/file          take a pre-mutation file snapshot, returns abs path
#   backup/node          take a pre-mutation scene-tree (PackedScene) snapshot
#   backup/check_exists  prune turn entries whose snapshots are GC'd
#   turn/revert          restore/delete per-change file + node outcomes
#   turn/accept          tear down a turn's backup subtree
#
# Implementations live on BackupManager — these handlers just unmarshal
# arguments and roll up per-change outcomes. Scene-tree mutations
# (gameObjectChanges in the wire payload) are restored via PackedScene
# re-instantiation; see BackupManager.backup_node / restore_node for the
# owner-rewiring dance PackedScene.pack requires in editor sessions.
func _main_dispatch_backup_file(request_id: String, request: Dictionary) -> Dictionary:
	var file_path: String = str(request.get("filePath", ""))
	if file_path.is_empty():
		return _make_error(request_id, "filePath is required")
	if not (file_path.begins_with("res://") or file_path.begins_with("user://")):
		# Lift Unity-style "Assets/Player.cs" to a res:// URI. Same trim the
		# bridge tools' parse_path_arg helper does — the client's wire
		# format is engine-agnostic, the bridge normalizes here.
		if file_path.begins_with("/"):
			file_path = file_path.substr(1)
		file_path = "res://" + file_path
	var turn_id: String = str(request.get("turnId", ""))
	# If the source file doesn't exist there's nothing to back up — a
	# create_*-style tool is about to write it for the first time. Return
	# success with no backupPath so the client records a "file_created"
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


func _main_dispatch_backup_node(request_id: String, request: Dictionary) -> Dictionary:
	# Pre-mutation snapshot of a scene-tree node. The client calls this
	# before scene-tree-mutating tools (delete_node, set_node_transform,
	# rename_node, etc.) so the turn can be reverted. The bridge picks the
	# backup location (per-turn subdir under .gladekit-backups/nodes/) so
	# the client doesn't have to know the project root.
	#
	# Returns success=true with backupPath="" when the node doesn't exist
	# yet (a create_*-style mutation is about to add it). Mirrors
	# backup/file's "source did not exist" branch — the client then
	# records a `gameobject_created` change so revert deletes the node
	# instead of restoring it.
	var node_path: String = str(request.get("nodePath", ""))
	if node_path.is_empty():
		return _make_error(request_id, "nodePath is required")
	var turn_id: String = str(request.get("turnId", ""))
	if turn_id.is_empty():
		return _make_error(request_id, "turnId is required")

	var node: Node = ToolUtils.find_node_by_path(node_path)
	if node == null:
		return {
			"id": request_id,
			"success": true,
			"backupPath": "",
			"note": "node did not exist at backup time (likely a create-style mutation)",
		}
	var root: Node = EditorInterface.get_edited_scene_root()
	if node == root:
		# Root-level mutations would need EditorInterface.set_edited_scene
		# on restore — out of scope for this revert flow. Surface clearly
		# instead of silently no-op'ing.
		return _make_error(request_id, "scene root cannot be backed up via backup/node; close/reopen the scene to undo root mutations")

	var result := BackupManager.backup_node(node, node_path, turn_id)
	if not result.get("success", false):
		return _make_error(request_id, str(result.get("error", "backup_node failed")))
	return {
		"id": request_id,
		"success": true,
		"backupPath": str(result.get("backup_path", "")),
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
	# Open scenes whose .tscn we rewind on disk — reloaded through the editor
	# after the node pass so the user isn't prompted to reload from disk.
	var restored_scene_paths: Array[String] = []
	# Every scene whose file this turn touched (saved/created). Used after the
	# node pass to re-persist the edited scene when its file change couldn't be
	# restored — otherwise a script/resource the revert deleted stays referenced
	# on disk and the scene fails to load next open.
	var turn_scene_paths: Array[String] = []
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
		if file_path.get_extension() in ["tscn", "scn"] and not turn_scene_paths.has(file_path):
			turn_scene_paths.append(file_path)
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
					if file_path.get_extension() in ["tscn", "scn"] and not restored_scene_paths.has(file_path):
						restored_scene_paths.append(file_path)
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

	# Scene-tree (node) revert. Iterates gameObjectChanges in reverse order
	# so within a single turn the most recent mutation undoes first
	# (matches Ctrl-Z intuition for stacked operations on the same node).
	var go_changes_raw = request.get("gameObjectChanges", [])
	var gameobjects_restored: int = 0
	var gameobjects_deleted: int = 0
	if go_changes_raw is Array:
		var go_changes: Array = (go_changes_raw as Array).duplicate()
		go_changes.reverse()
		for entry in go_changes:
			if not (entry is Dictionary):
				errors.append({"error": "gameObjectChanges entry was not a Dictionary"})
				continue
			var change: Dictionary = entry
			var change_type: String = str(change.get("changeType", "")).to_lower()
			var go_path: String = str(change.get("gameObjectPath", ""))
			var state_backup: String = str(change.get("stateBackupPath", ""))
			if go_path.is_empty():
				errors.append({"error": "gameObjectChanges entry missing gameObjectPath", "change": change})
				continue
			match change_type:
				"created":
					# Undo a creation: delete the node. No backup to consult.
					var del := BackupManager.delete_node_at(go_path)
					if del.get("success", false):
						if del.get("deleted", false):
							gameobjects_deleted += 1
					else:
						errors.append({"gameObjectPath": go_path, "changeType": change_type, "error": del.get("error", "delete failed")})
				"deleted":
					# Re-create the node from its PackedScene backup. Parse the
					# scene-relative path into parent + name; the parent must
					# still exist for the restore to attach.
					if state_backup.is_empty():
						errors.append({"gameObjectPath": go_path, "changeType": change_type, "error": "stateBackupPath required for deleted revert"})
						continue
					var parent_split := _split_node_path_into_parent_and_name(go_path)
					var parent_node: Node = ToolUtils.find_node_by_path(parent_split.parent_path)
					if parent_node == null:
						errors.append({"gameObjectPath": go_path, "changeType": change_type, "error": "parent '%s' not found in current scene" % parent_split.parent_path})
						continue
					var restore := BackupManager.restore_node(state_backup, parent_node, parent_split.node_name)
					if restore.get("success", false):
						gameobjects_restored += 1
					else:
						errors.append({"gameObjectPath": go_path, "changeType": change_type, "error": restore.get("error", "restore failed")})
				"modified":
					# Delete the current (mutated) node, then re-attach the
					# backup in its place. Preserves sibling index so the
					# restored node lands at its original position.
					if state_backup.is_empty():
						errors.append({"gameObjectPath": go_path, "changeType": change_type, "error": "stateBackupPath required for modified revert"})
						continue
					var current_node: Node = ToolUtils.find_node_by_path(go_path)
					if current_node == null:
						# Modified-then-deleted within the same turn — restore is
						# functionally identical to the "deleted" branch above.
						var parent_split2 := _split_node_path_into_parent_and_name(go_path)
						var parent_node2: Node = ToolUtils.find_node_by_path(parent_split2.parent_path)
						if parent_node2 == null:
							errors.append({"gameObjectPath": go_path, "changeType": change_type, "error": "node + parent both missing — can't restore"})
							continue
						var restore2 := BackupManager.restore_node(state_backup, parent_node2, parent_split2.node_name)
						if restore2.get("success", false):
							gameobjects_restored += 1
						else:
							errors.append({"gameObjectPath": go_path, "changeType": change_type, "error": restore2.get("error", "restore failed")})
						continue
					var parent_node3: Node = current_node.get_parent()
					if parent_node3 == null:
						errors.append({"gameObjectPath": go_path, "changeType": change_type, "error": "current node has no parent (scene root?)"})
						continue
					var sibling_index: int = parent_node3.get_children().find(current_node)
					var node_name: String = current_node.name
					ToolUtils.deselect_before_free(current_node)
					parent_node3.remove_child(current_node)
					current_node.free()
					var restore3 := BackupManager.restore_node(state_backup, parent_node3, node_name, sibling_index)
					if restore3.get("success", false):
						gameobjects_restored += 1
					else:
						errors.append({"gameObjectPath": go_path, "changeType": change_type, "error": restore3.get("error", "restore failed")})
				_:
					errors.append({"gameObjectPath": go_path, "changeType": change_type, "error": "unknown changeType"})

	# Tell the editor's filesystem to rescan so the rewound state shows up
	# without the user manually triggering Project → Reload Current Project.
	# Best-effort: a failed scan doesn't fail the revert. (We already scanned
	# above after file changes; second scan is cheap and keeps node restores
	# visible too in case the scene happened to load any new resources.)

	# Reload any open scene whose .tscn was rewound on disk above. restore_file
	# writes the file directly, leaving the editor's open copy out of sync — on
	# the next editor refocus Godot would prompt "scene is newer on disk, reload?".
	# Reloading through the editor reconciles the open scene with the reverted
	# file (no prompt) and surfaces the rewound state. Done AFTER the node pass so
	# the reload can't race the in-memory node restores; the reverted .tscn is the
	# source of truth, so any redundant in-memory restores are simply superseded.
	if not restored_scene_paths.is_empty():
		var open_scenes := EditorInterface.get_open_scenes()
		for scene_path in restored_scene_paths:
			if scene_path in open_scenes:
				EditorInterface.reload_scene_from_path(scene_path)

	# Re-persist the edited scene when its tree was rewound by the node pass but
	# its FILE could not be restored (e.g. save_scene's pre-save snapshot wasn't
	# captured this turn). Without this the on-disk .tscn keeps referencing a
	# script/resource the revert just deleted, and the scene fails to load next
	# open ("missing dependencies"). The reverted in-memory tree is the source of
	# truth, so we save it back through the editor (which also avoids the reload
	# prompt). Scoped tightly: only the edited scene, only when this turn saved
	# that scene's file, and only when its file wasn't already restored above
	# (a file-level revert + reload reconciles those; re-saving would fight it).
	if (gameobjects_restored + gameobjects_deleted) > 0:
		var edited_root := EditorInterface.get_edited_scene_root()
		if edited_root != null:
			var edited_path: String = edited_root.scene_file_path
			var needs_resave := (
				not edited_path.is_empty()
				and turn_scene_paths.has(edited_path)
				and not restored_scene_paths.has(edited_path)
			)
			if needs_resave:
				EditorInterface.save_scene()

	var total_changes: int = files_restored + files_deleted + gameobjects_restored + gameobjects_deleted
	var message: String
	if total_changes == 0 and not errors.is_empty():
		message = "No changes reverted — see errors for details."
	else:
		message = "Reverted %d change(s): %d file, %d node." % [
			total_changes,
			files_restored + files_deleted,
			gameobjects_restored + gameobjects_deleted,
		]

	var response: Dictionary = {
		"id": request_id,
		"success": errors.is_empty(),
		"message": message,
		"filesRestored": files_restored,
		"filesDeleted": files_deleted,
		"gameObjectsRestored": gameobjects_restored,
		"gameObjectsDeleted": gameobjects_deleted,
	}
	if not errors.is_empty():
		response["errors"] = errors
		response["error"] = "%d change(s) failed to revert" % errors.size()
	return response


# Split "Player/Sprite" → { parent_path: "Player", node_name: "Sprite" }.
# Handles edge cases: scene-root-relative single-name ("Player") → parent
# is "" (the scene root), name is "Player". Absolute paths starting with
# "/root/" are left to ToolUtils.find_node_by_path to interpret.
func _split_node_path_into_parent_and_name(node_path: String) -> Dictionary:
	var trimmed := node_path.strip_edges()
	if trimmed.is_empty():
		return {"parent_path": "", "node_name": ""}
	var last_slash := trimmed.rfind("/")
	if last_slash < 0:
		# Single token — name is the whole thing, parent is scene root.
		return {"parent_path": "", "node_name": trimmed}
	return {
		"parent_path": trimmed.substr(0, last_slash),
		"node_name": trimmed.substr(last_slash + 1),
	}


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


# Builds the orphan-reap startup notice. Kept as a separate helper because
# GDScript's % operator binds tighter than +, so formatting a multi-line
# string concatenation in place silently applies the args to only the last
# literal (a 0.6.4 regression caught in review). Static so unit tests can
# exercise it without spinning up the server.
static func _format_reap_message(reaped_count: int, killed_count: int) -> String:
	return (
		"reaped %d orphan play session(s) from a previous plugin instance "
		+ "(%d still running and killed). This is expected after a plugin hot-reload."
	) % [reaped_count, killed_count]


# ── Worker thread: accept, poll, send ────────────────────────────────────
# Owns _tcp_server, _peers, and the I/O loop. Touches main-thread state
# only via mutex-protected queues. Never calls EditorInterface or scene-tree
# APIs (those are not thread-safe).

func _thread_main() -> void:
	while not _thread_should_exit:
		_thread_accept()
		_thread_poll()
		_thread_expire_stalled_dispatches()
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
		# Must be set before accept_stream — buffers are allocated when the
		# connection is established.
		ws.inbound_buffer_size = WS_INBOUND_BUFFER_SIZE
		ws.outbound_buffer_size = WS_OUTBOUND_BUFFER_SIZE
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
	# Instance-based JSON.parse instead of the static JSON.parse_string:
	# the static helper push_errors to the editor Output panel on malformed
	# input, so a misbehaving client could spam red engine errors at the
	# user. The instance method is silent and exposes the parse diagnostics,
	# which belong in the structured response to the client instead.
	var json := JSON.new()
	if json.parse(packet_text) != OK:
		_enqueue_send(peer, _make_error(
			"",
			"Request body is not valid JSON: %s (line %d)" % [json.get_error_message(), json.get_error_line()]
		))
		return
	if not (json.data is Dictionary):
		_enqueue_send(peer, _make_error("", "Request body is not a valid JSON object"))
		return
	var request: Dictionary = json.data
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
				"projectName": _project_name,
				"projectPath": _project_path,
				"engineMode": mode,
				"toolCount": _registry.get_tool_count(),
				# How long since the editor's main thread last made progress.
				# Health answers from the worker thread, so this stays readable
				# even while the main thread is blocked — clients use it to
				# tell "editor wedged behind a modal dialog" apart from
				# "bridge gone" after a tool timeout.
				"mainThreadStalledMsec": _msec_since_main_tick(Time.get_ticks_msec()),
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
			_enqueue_main_dispatch(peer, request, request_id)
		"context/gather":
			# One-shot project orientation snapshot for clients that want a
			# pre-prompt context bundle. Aggregates get_project_info +
			# get_scene_tree + recent_errors so the agent doesn't burn
			# 2-3 round-trips on every Godot session's first turn.
			# Scene-tree access requires the main thread.
			_enqueue_main_dispatch(peer, request, request_id)
		"backup/file", "backup/node", "backup/check_exists", "turn/revert", "turn/accept":
			# File-level revert/backup endpoints. Routed through the main
			# thread for two reasons: (a) FileAccess + DirAccess operations
			# are safer on the editor's main thread, and (b) turn/revert
			# refreshes EditorInterface.get_resource_filesystem() after the
			# restore so the editor immediately reflects the rewound state —
			# that call is main-thread-only. These endpoints don't touch
			# the scene tree, so latency is dominated by disk I/O.
			_enqueue_main_dispatch(peer, request, request_id)
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


# ── Main-thread stall watchdog (worker thread) ───────────────────────────
# The editor's main thread can wedge: a modal dialog pumping its own event
# loop, a long synchronous import/scan, or a tool that blocks. When that
# happens the dispatch queue stops draining, and without intervention every
# queued request rides out the client's full timeout with a generic error —
# making the bridge look dead while health still answers. The worker thread
# (which owns no editor state and never blocks) expires queued entries past
# MAIN_DISPATCH_STALL_TIMEOUT_MSEC and answers them with a structured error
# naming the stall and how to clear it. Expired entries are removed under
# the queue mutex before the main thread can pop them, so a request can
# never receive both the stall error and a late tool response.

func _thread_expire_stalled_dispatches() -> void:
	var now := Time.get_ticks_msec()
	var expired: Array = []
	_pending_main_dispatches_mutex.lock()
	if not _pending_main_dispatches.is_empty():
		var split := _split_expired_dispatches(_pending_main_dispatches, now, MAIN_DISPATCH_STALL_TIMEOUT_MSEC)
		expired = split["expired"]
		_pending_main_dispatches = split["remaining"]
	_pending_main_dispatches_mutex.unlock()
	if expired.is_empty():
		return
	var stalled_msec := _msec_since_main_tick(now)
	for entry: Dictionary in expired:
		var request: Dictionary = entry["request"]
		var label := str(request.get("toolName", "")) if request.has("toolName") else str(request.get("endpoint", "request"))
		var waited_msec: int = now - int(entry.get("queued_at_msec", now))
		var response := _make_error(
			str(entry["request_id"]),
			(
				"'%s' was never dispatched: the Godot editor's main thread has not "
				+ "processed bridge work for %.1fs (request queued %.1fs ago). The "
				+ "editor is likely blocked by a modal dialog or a long synchronous "
				+ "operation."
			) % [label, stalled_msec / 1000.0, waited_msec / 1000.0]
		)
		response["mainThreadStalledMsec"] = stalled_msec
		response["possible_solutions"] = [
			"Switch to the Godot editor window and dismiss any open modal dialog",
			"If the editor is busy importing or scanning, wait for it to finish, then retry",
			"If the editor is permanently unresponsive, restart it — the bridge comes back automatically",
		]
		push_warning("[GladeKit MCP Bridge] " + str(response["message"]))
		_enqueue_send(entry["peer"], response)


# Pure splitter so the expiry policy is unit-testable without threads or an
# editor. Entries missing a queued_at_msec stamp are treated as fresh.
static func _split_expired_dispatches(dispatches: Array, now_msec: int, threshold_msec: int) -> Dictionary:
	var expired: Array = []
	var remaining: Array = []
	for entry: Dictionary in dispatches:
		var queued_at: int = int(entry.get("queued_at_msec", now_msec))
		if now_msec - queued_at >= threshold_msec:
			expired.append(entry)
		else:
			remaining.append(entry)
	return {"expired": expired, "remaining": remaining}


func _msec_since_main_tick(now_msec: int) -> int:
	_cached_mutex.lock()
	var last := _last_main_tick_msec
	_cached_mutex.unlock()
	return maxi(0, now_msec - last)


# ── Cross-thread helpers ─────────────────────────────────────────────────

func _enqueue_main_dispatch(peer: WebSocketPeer, request: Dictionary, request_id: String) -> void:
	_pending_main_dispatches_mutex.lock()
	_pending_main_dispatches.append({
		"peer": peer,
		"request": request,
		"request_id": request_id,
		"queued_at_msec": Time.get_ticks_msec(),
	})
	_pending_main_dispatches_mutex.unlock()


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


# Levenshtein-ranked tool names within UNKNOWN_TOOL_SUGGESTION_DISTANCE_THRESHOLD
# of `query`, capped at UNKNOWN_TOOL_SUGGESTION_MAX. Returns [] when nothing
# qualifies — the dispatcher then drops the `possible_solutions` field so a
# wild-miss error stays clean instead of spamming unrelated guesses.
func _suggest_tool_names(query: String) -> Array:
	var ql := query.to_lower()
	var scored: Array = []
	for n in _registry.get_tool_names():
		var dist := ToolUtils.levenshtein(ql, String(n).to_lower())
		if dist <= UNKNOWN_TOOL_SUGGESTION_DISTANCE_THRESHOLD:
			scored.append([dist, String(n)])
	if scored.is_empty():
		return []
	scored.sort_custom(func(a, b): return a[0] < b[0])
	var out: Array = []
	for i in range(min(UNKNOWN_TOOL_SUGGESTION_MAX, scored.size())):
		out.append(scored[i][1])
	return out


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
