extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Kills a play session started by run_project. Returns the final drained
# stdout/stderr so the agent can examine any last-second output.
#
# Identifier resolution: agents reliably confuse the response fields
# `session_id` (the manager's internal id, e.g. "1") and `pid` (the OS
# process id, e.g. 23696). This tool accepts EITHER:
#   * session_id arg (preferred — matches the field name in run_project's response)
#   * pid arg (numeric — fallback when the agent grabbed the wrong field)
#   * session_id arg that's actually a pid string ("23696") or a mangled
#     form ("pid 23696", "pid=23696") — best-effort regex extraction of
#     the first integer, then matched against active sessions
#
# Args:
#   session_id: String — session id from run_project (e.g. "1")
#   pid:        int    — fallback: kill the session matching this pid
#
# Response payload:
#   session_id, pid, stdout, stderr, was_running, exit_code

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const PlaySessionManager = preload("res://addons/com.gladekit.mcp-bridge/services/play_session_manager.gd")


func _init() -> void:
	tool_name = "stop_project"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var resolved_id: String = _resolve_session_id(args)
	if resolved_id.is_empty():
		var active: String = _active_sessions_summary()
		return ToolUtils.error_with_solutions(
			"Could not resolve a session to stop from the provided args",
			[
				"Pass session_id (the string from run_project, e.g. session_id='1')",
				"Or pass pid (the integer from run_project, e.g. pid=23696)",
				active,
			]
		)
	var result := PlaySessionManager.stop(resolved_id)
	if result.has("error"):
		return ToolUtils.error_with_solutions(
			result["error"],
			["Confirm the session is still active via the active session list above", _active_sessions_summary()]
		)
	# A verify run (--quit-after) self-terminates before the model gets here, so
	# "already exited" is the normal, successful outcome — not a failure. Report
	# it as success with the captured output rather than a scary error card.
	var already_exited: bool = bool(result.get("already_exited", false))
	var msg: String
	if already_exited:
		msg = "Session %s had already exited (%s); returning its final captured output." % [
			resolved_id, String(result.get("reason", "exited"))
		]
	else:
		msg = "Stopped session %s (pid %d)" % [resolved_id, int(result["pid"])]
	return ToolUtils.success(msg, {
		"session_id": resolved_id,
		"pid": int(result["pid"]),
		"stdout": result["stdout"],
		"stderr": result["stderr"],
		"was_running": result["was_running"],
		"exit_code": result["exit_code"],
		"already_exited": already_exited,
	})


# Walks the (small) active-sessions list and returns the canonical
# session_id matching either the provided session_id or pid. Returns "" if
# no match — the caller surfaces a helpful error with the actual active set.
func _resolve_session_id(args: Dictionary) -> String:
	# Match across BOTH live sessions and recently-exited ones. A verify run
	# self-terminates via --quit-after, so by the time stop_project is called
	# the session is often already reaped — but stopping it is still the right
	# (idempotent) outcome, so it must remain resolvable. list_sessions() reaps
	# first, populating the graveyard, so the two lists together are current.
	var sessions: Array = PlaySessionManager.list_sessions()
	var sessions_and_ghosts: Array = sessions + PlaySessionManager.list_recently_exited()

	# First try the obvious session_id arg, exact match.
	var sid_arg: String = ToolUtils.parse_string_arg(args, "session_id")
	if not sid_arg.is_empty():
		for s in sessions_and_ghosts:
			if String(s.get("session_id", "")) == sid_arg:
				return sid_arg
		# Maybe the agent passed a pid in the session_id slot. Extract the
		# first integer ("pid 23696" → 23696) and try matching it as pid.
		var extracted: int = _first_int(sid_arg)
		if extracted > 0:
			for s in sessions_and_ghosts:
				if int(s.get("pid", 0)) == extracted:
					return String(s.get("session_id", ""))

	# Explicit pid arg.
	if args.has("pid"):
		var pid_int: int = ToolUtils.parse_int_arg(args, "pid", 0)
		if pid_int > 0:
			for s in sessions_and_ghosts:
				if int(s.get("pid", 0)) == pid_int:
					return String(s.get("session_id", ""))

	return ""


# Returns the first contiguous integer in the string, or 0 if none. Tolerates
# the model's creative session-id mangling: "pid 23696", "pid=23696",
# "session pid 23696", etc. all extract to 23696.
func _first_int(s: String) -> int:
	var current: String = ""
	for i in s.length():
		var c: String = s[i]
		if c >= "0" and c <= "9":
			current += c
		elif not current.is_empty():
			break
	if current.is_empty():
		return 0
	return int(current)


# Builds a one-line summary of currently active sessions for the
# error-hint surface, so the model can self-correct on the retry.
func _active_sessions_summary() -> String:
	var sessions: Array = PlaySessionManager.list_sessions()
	if sessions.is_empty():
		return "No active sessions — there is nothing to stop right now."
	var parts: Array = []
	for s in sessions:
		parts.append("session_id='%s' pid=%d" % [String(s.get("session_id", "")), int(s.get("pid", 0))])
	return "Active sessions: " + ", ".join(parts)
