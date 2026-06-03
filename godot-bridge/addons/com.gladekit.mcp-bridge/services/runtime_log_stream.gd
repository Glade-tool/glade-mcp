extends RefCounted

# Editor-only structured ring buffer of Godot runtime errors.
#
# Mirrors the Unity bridge's RuntimeLogStream (ring buffer of Error/Exception
# entries with monotonic cursors + content fingerprints) but adapted to
# Godot's different process model: Unity captures runtime errors via an
# in-process callback (Application.logMessageReceivedThreaded) because the
# game runs inside the editor's domain. Godot's play session is a separate
# `godot` subprocess spawned by PlaySessionManager, so we parse errors out
# of that subprocess's stderr stream instead.
#
# Wire-in point: PlaySessionManager calls ingest_chunk(session_id, chunk)
# every time it reads bytes from a session's stderr pipe (drain, stop, or
# the passive tick_all_sessions used by get_runtime_events). The stream
# does its own line-splitting so chunk boundaries inside an error block
# don't lose information; trailing partial lines carry across chunks per
# session.
#
# Consumer pattern: caller-tracked cursor. get_events_since_cursor returns
# every event with cursor > since_cursor, in order. Multiple consumers can
# poll independently without stealing events from each other (no internal
# drain pointer mutation on read).

const MAX_ENTRIES := 500
const FINGERPRINT_STACK_PREFIX_CHARS := 500

# Line prefixes Godot emits on stderr for failed asserts, push_error,
# script exceptions, and engine-level errors. WARNING: is intentionally
# absent — we drop warnings to match Unity's "Error + Exception only"
# behavior.
#
# Godot version differences to keep in mind:
#   * Godot 4 `push_error("msg")` → "USER ERROR: msg"  (NOT "USER SCRIPT ERROR")
#   * Godot 3 `push_error("msg")` → "USER SCRIPT ERROR: msg"
#   * Engine-level errors (nil deref, type mismatch, etc.) → "SCRIPT ERROR: msg"
#   * Bare engine errors → "ERROR: msg"
# Both "USER ERROR" and "USER SCRIPT ERROR" must be matched BEFORE "ERROR:"
# so a "USER ERROR: foo" line doesn't accidentally route through the bare
# ERROR: branch with "USER " prepended to the message. Match table is
# iterated in declaration order — keep the longer/more-specific prefixes
# at the top.
const _ERROR_PREFIXES := [
	["USER SCRIPT ERROR:", "USER_SCRIPT_ERROR"],
	["USER ERROR:",        "USER_ERROR"],
	["SCRIPT ERROR:",      "SCRIPT_ERROR"],
	["ERROR:",             "ERROR"],
]

# Stack-frame line marker. Godot prints frames with a 3-space indent followed
# by "at:". The indent is consistent across 4.x; strip leading whitespace
# defensively before the comparison.
const _STACK_FRAME_MARKER := "at:"

static var _ring: Array = []
static var _next_cursor: int = 0
static var _dropped_due_to_overflow: int = 0
static var _total_observed: int = 0

# Per-session parser state.
#   _session_residue: incomplete trailing line carried into the next chunk.
#   _session_open_event: in-progress event (header seen, stack frames may
#                        still be arriving). Closed when a non-stack line
#                        lands or when flush_session() runs at process end.
static var _session_residue: Dictionary = {}
static var _session_open_event: Dictionary = {}


# Feed a chunk of bytes just read from a play session's stderr pipe.
# Idempotent in the sense that each byte is only ingested once — callers
# are responsible for not passing the same chunk twice (PlaySessionManager
# guarantees this because OS pipes are read-destructive).
static func ingest_chunk(session_id: String, text: String) -> void:
	if text.is_empty():
		return
	var carry: String = String(_session_residue.get(session_id, ""))
	var combined := carry + text
	var newline_index := combined.rfind("\n")
	if newline_index < 0:
		# No complete line in the buffer yet; hold for the next chunk.
		_session_residue[session_id] = combined
		return
	var complete := combined.substr(0, newline_index)
	var leftover := combined.substr(newline_index + 1)
	_session_residue[session_id] = leftover
	for line in complete.split("\n", true):
		_process_line(session_id, String(line))


# Drain any pending open event for a session — call from
# PlaySessionManager.stop() so a trailing error whose final stack frame is
# the last line of stderr isn't lost when the process exits.
static func flush_session(session_id: String) -> void:
	# Any residue at process end is treated as a final line.
	var leftover: String = String(_session_residue.get(session_id, ""))
	if not leftover.is_empty():
		_process_line(session_id, leftover)
		_session_residue.erase(session_id)
	_close_open_event(session_id)


# Return events with cursor > since_cursor, capped at limit. Snapshot copy —
# safe to iterate without holding state.
static func get_events_since_cursor(since_cursor: int, limit: int = 200) -> Array:
	var out: Array = []
	for event in _ring:
		if int(event["cursor"]) <= since_cursor:
			continue
		out.append(event)
		if out.size() >= limit:
			break
	return out


# Newest cursor in the buffer, or 0 if empty. Used by start_runtime_observation
# to snapshot a baseline so prior errors don't retroactively surface.
static func latest_cursor() -> int:
	if _ring.is_empty():
		return 0
	return int(_ring[_ring.size() - 1]["cursor"])


static func current_size() -> int:
	return _ring.size()


static func dropped_due_to_overflow() -> int:
	return _dropped_due_to_overflow


static func total_events_observed() -> int:
	return _total_observed


# Test / diagnostic helper. Wipes state. Not called from production paths.
static func reset() -> void:
	_ring.clear()
	_next_cursor = 0
	_dropped_due_to_overflow = 0
	_total_observed = 0
	_session_residue.clear()
	_session_open_event.clear()


# ── Parser internals ──────────────────────────────────────────────────────

static func _process_line(session_id: String, line: String) -> void:
	# Stack frames: "   at: Player.gd:42 @ _on_pressed()". Leading whitespace
	# is significant in Godot's output (it visually pairs the frame with the
	# preceding ERROR line), but we strip it before comparison.
	var stripped := line.strip_edges(true, false)
	if stripped.begins_with(_STACK_FRAME_MARKER):
		if not _session_open_event.has(session_id):
			return  # orphan stack frame with no preceding error header
		var open: Dictionary = _session_open_event[session_id]
		var current_stack := String(open.get("stack_trace", ""))
		if current_stack.is_empty():
			open["stack_trace"] = line
		else:
			open["stack_trace"] = current_stack + "\n" + line
		_session_open_event[session_id] = open
		return

	# Any non-stack line closes the currently-open event (if any) before we
	# look for a new header. This way an error followed by a print() line
	# emits the error immediately, not on the next ingest_chunk.
	_close_open_event(session_id)

	for prefix_pair in _ERROR_PREFIXES:
		var prefix: String = prefix_pair[0]
		var log_type: String = prefix_pair[1]
		if line.begins_with(prefix):
			var message := line.substr(prefix.length()).strip_edges()
			_session_open_event[session_id] = {
				"message": message,
				"stack_trace": "",
				"log_type": log_type,
				"timestamp": Time.get_unix_time_from_system(),
			}
			return


static func _close_open_event(session_id: String) -> void:
	if not _session_open_event.has(session_id):
		return
	var open: Dictionary = _session_open_event[session_id]
	_session_open_event.erase(session_id)
	if open.is_empty():
		return
	_push_event(open)


static func _push_event(open: Dictionary) -> void:
	var event := {
		"cursor": _next_cursor,
		"message": String(open["message"]),
		"stack_trace": String(open["stack_trace"]),
		"log_type": String(open["log_type"]),
		"timestamp": float(open["timestamp"]),
		"fingerprint": _fingerprint(String(open["message"]), String(open["stack_trace"])),
	}
	_next_cursor += 1
	_total_observed += 1
	_ring.append(event)
	while _ring.size() > MAX_ENTRIES:
		_ring.pop_front()
		_dropped_due_to_overflow += 1


# Fingerprint = hash(message + first N chars of stack). Stable across the
# same logical error within a session; intentionally drifts when a script
# edit shifts line numbers in the stack (so an autonomous fixer gets a
# fresh shot at the same error after a recompile). Matches the Unity-side
# semantics in Services/RuntimeLogStream.cs.
static func _fingerprint(message: String, stack_trace: String) -> String:
	var head := stack_trace
	if head.length() > FINGERPRINT_STACK_PREFIX_CHARS:
		head = head.substr(0, FINGERPRINT_STACK_PREFIX_CHARS)
	var payload := message + "\n" + head
	return "%x" % payload.hash()
