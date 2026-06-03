extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Returns structured runtime errors captured since the caller's cursor.
# Read-only. Designed for incremental polling — the agent passes the previous
# response's `next_cursor` on subsequent calls to receive only new events.
#
# Errors are parsed out of active PlaySessionManager subprocess stderr feeds
# by RuntimeLogStream. Captured prefixes: ERROR, SCRIPT ERROR, USER SCRIPT
# ERROR (Godot 4.x error format). WARNING and plain stdout are intentionally
# dropped — this stream is errors-only, matching the Unity bridge's behavior.
#
# Mirrors Unity's get_runtime_events. The shape difference vs that tool:
# Godot's `log_type` enum is {ERROR, SCRIPT_ERROR, USER_SCRIPT_ERROR}
# rather than {Error, Exception} because Godot doesn't distinguish them at
# the stderr layer.
#
# Args:
#   since_cursor: int — return events with cursor > this value. Default 0
#                       (returns everything currently in the ring buffer).
#   limit:        int — max events per call. Default 200, hard-capped 2000.
#                       Events past the limit remain for the next poll.
#   wait_ms:      int — optional blocking wait (max 5000) for new events to
#                       arrive. The tool re-drains active session pipes every
#                       100ms until events appear OR the deadline passes,
#                       then returns. Use this right after run_project so
#                       the first poll doesn't beat the subprocess to _ready.
#                       Default 0 (return immediately, no wait).
#
# Response payload:
#   events:                  [Dict] each {cursor, message, stack_trace,
#                                          log_type, timestamp, fingerprint}
#   next_cursor:             int  — pass this on the next poll
#   play_mode_active:        bool — true if any PlaySessionManager session is running
#   observation_active:      bool
#   ring_buffer_size:        int  — current ring size (informational)
#   dropped_due_to_overflow: int  — total evicted by buffer overflow this session
#   total_events_observed:   int  — total ever ingested since editor start
#   raw_stderr_bytes:        int  — diagnostic: total bytes captured from
#                                    subprocess stderr (across active sessions).
#                                    Empty events + raw_stderr_bytes>0 → parser
#                                    missed a prefix. Empty events + 0 bytes →
#                                    subprocess didn't write to stderr (libc
#                                    buffering, no errors fired, or pipe issue).
#   raw_stdout_bytes:        int  — same for stdout (print() output etc.).
#   raw_stderr_tail:         String — last ~500 chars of stderr from the
#                                      largest session, for debugging unknown
#                                      prefixes.
#
# Composability: this tool pumps active session pipes before reading the ring,
# but does NOT consume the user-facing stdout/stderr buffer that
# get_debug_output reads from. The two tools are independent — agents can use
# them in either order, on the same session, without interference.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const PlayModeObserver = preload("res://addons/com.gladekit.mcp-bridge/services/play_mode_observer.gd")
const RuntimeLogStream = preload("res://addons/com.gladekit.mcp-bridge/services/runtime_log_stream.gd")
const PlaySessionManager = preload("res://addons/com.gladekit.mcp-bridge/services/play_session_manager.gd")

const DEFAULT_LIMIT := 200
const HARD_CAP := 2000
const MAX_WAIT_MS := 5000      # cap on blocking wait — protects editor responsiveness
const POLL_INTERVAL_MS := 100  # how often to re-drain inside the wait loop


func _init() -> void:
	tool_name = "get_runtime_events"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var since_cursor: int = ToolUtils.parse_int_arg(args, "since_cursor", 0)
	var limit: int = clamp(ToolUtils.parse_int_arg(args, "limit", DEFAULT_LIMIT), 1, HARD_CAP)
	var wait_ms: int = clamp(ToolUtils.parse_int_arg(args, "wait_ms", 0), 0, MAX_WAIT_MS)

	# Refresh the structured stream from any output that landed since the
	# last drain. Cheap when no sessions are running (the for-loop is a no-op).
	PlaySessionManager.tick_all_sessions()

	var events: Array = RuntimeLogStream.get_events_since_cursor(since_cursor, limit)

	# If the caller asked us to wait, poll on a short interval until events
	# show up or the deadline elapses. This is the fix for "agent calls
	# get_runtime_events 50ms after run_project" — the subprocess takes
	# 500ms-2s to boot and fire _ready, so the first poll is always empty
	# without a wait. Blocks the bridge's main thread (and therefore the
	# editor UI) for up to MAX_WAIT_MS; capped at 5s to keep that bounded.
	if events.is_empty() and wait_ms > 0:
		var deadline_ms: int = Time.get_ticks_msec() + wait_ms
		while events.is_empty() and Time.get_ticks_msec() < deadline_ms:
			OS.delay_msec(POLL_INTERVAL_MS)
			PlaySessionManager.tick_all_sessions()
			events = RuntimeLogStream.get_events_since_cursor(since_cursor, limit)

	var next_cursor: int = since_cursor
	if not events.is_empty():
		next_cursor = int(events[events.size() - 1]["cursor"])

	var play_mode_active := false
	for s in PlaySessionManager.list_sessions():
		if bool(s.get("running", false)):
			play_mode_active = true
			break

	# Pull stderr/stdout diagnostics so the agent can self-diagnose an empty
	# response: bytes>0+events=0 → parser missed a prefix; both 0 → subprocess
	# never wrote to stderr (possible libc buffering or no errors fired yet).
	var diag: Dictionary = PlaySessionManager.get_buffer_diagnostics()

	# Bake the diagnostic into the message field so it surfaces in chat even
	# when the model only quotes the message back. Without this, models tend
	# to read "No new runtime events" and stop looking — never noticing the
	# raw_stderr_bytes counter in the structured payload.
	var msg: String
	if not events.is_empty():
		msg = "%d runtime event(s)" % events.size()
	elif int(diag["raw_stderr_bytes"]) > 0:
		msg = ("No new runtime events (but the bridge DID capture %d bytes of stderr — "
			+ "the parser missed a prefix it doesn't recognize. Inspect raw_stderr_tail "
			+ "in this response to see what slipped through.)") % int(diag["raw_stderr_bytes"])
	else:
		msg = ("No new runtime events (raw_stderr_bytes=0 — the subprocess wrote nothing "
			+ "to stderr that the bridge captured. Possible causes: no errors fired yet "
			+ "(retry with wait_ms=3000 right after run_project), subprocess stderr is "
			+ "libc-buffered (Windows), or no play session is currently running.)")

	return ToolUtils.success(msg, {
		"events": events,
		"next_cursor": next_cursor,
		"play_mode_active": play_mode_active,
		"observation_active": PlayModeObserver.is_observation_active(),
		"ring_buffer_size": RuntimeLogStream.current_size(),
		"dropped_due_to_overflow": RuntimeLogStream.dropped_due_to_overflow(),
		"total_events_observed": RuntimeLogStream.total_events_observed(),
		"raw_stderr_bytes": diag["raw_stderr_bytes"],
		"raw_stdout_bytes": diag["raw_stdout_bytes"],
		"raw_stderr_tail": diag["raw_stderr_tail"],
	})
