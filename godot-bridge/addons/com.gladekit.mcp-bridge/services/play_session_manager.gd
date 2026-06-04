extends RefCounted

# Manages headless `godot` subprocesses spawned by the `run_project` tool.
# Holds the process state across tool calls so `get_debug_output` can drain
# accumulated stdout/stderr and `stop_project` can kill the right PID.
#
# Architectural note: this is the differentiating piece vs godot-mcp.
# Their stdio-MCP architecture has the same feature, but each call has to
# re-shell-out — they can't preserve a live editor while ALSO running a
# play session. We can, because the bridge stays in the editor process
# while the play session runs as a separate child process.
#
# State is process-local (static dictionary keyed by an internal session
# id). Multiple concurrent play sessions are supported, though the common
# case is one at a time.
#
# Plugin-reload survival: editing any bridge .gd file makes Godot
# re-instantiate static state, which would orphan every running child
# process (we'd lose the PIDs and never kill them). On `start()` we mirror
# the PID + project path into user://gladekit-godot-bridge/sessions.json
# (writes are best-effort; never block the tool). On bridge boot, the WS
# server calls `reap_orphans()` to read that file, OS.is_process_running()
# each PID, and kill any survivor. The pipe FDs from the previous process
# instance are gone, so we can't re-attach output capture — but we can at
# least prevent the zombie buildup.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const RuntimeLogStream = preload("res://addons/com.gladekit.mcp-bridge/services/runtime_log_stream.gd")

# Where the PID mirror lives. user:// resolves to the editor's user data dir
# (~/Library/Application Support/Godot/app_userdata/<project>/ on macOS,
# %APPDATA%\Godot\app_userdata\<project>\ on Windows, etc.) — outside res://
# so the project's filesystem scanner doesn't try to import it.
const SESSIONS_PERSIST_PATH := "user://gladekit-godot-bridge/sessions.json"

# Maps session_id (auto-incrementing int as string) → session dict.
# Session dict shape:
#   { "pid": int,
#     "command": String,
#     "stdio": FileAccess,        # captured stdout
#     "stderr": FileAccess,       # captured stderr
#     "started_unix": float,
#     "stdout_buffer": String,    # appended as we drain
#     "stderr_buffer": String,
#     "exit_code": int|null,      # null while running
#     "project_path": String }
static var _sessions: Dictionary = {}
static var _next_id: int = 1


# Spawn `godot` as a subprocess. Returns:
#   { "session_id": String, "pid": int, "command": String } on success
#   { "error": String } on failure.
static func start(project_path: String, scene: String = "", extra_args: Array = []) -> Dictionary:
	if project_path.is_empty():
		return {"error": "project_path is required"}
	# Use the same godot binary the editor is running.
	var godot_exe := OS.get_executable_path()
	if godot_exe.is_empty():
		return {"error": "could not resolve current Godot executable path"}
	var args: Array = ["--path", project_path]
	if not scene.is_empty():
		args.append(scene)
	for a in extra_args:
		args.append(str(a))
	# execute_with_pipe (Godot 4.3+) gives us {stdio, stderr, pid} so we
	# can drain output incrementally instead of waiting for the process
	# to exit (the cold-launch failure mode godot-mcp suffers from).
	var pipe = OS.execute_with_pipe(godot_exe, args, false)
	if pipe == null or pipe.is_empty():
		return {"error": "OS.execute_with_pipe failed to spawn godot"}
	if not pipe.has("pid"):
		return {"error": "spawn returned no pid"}
	var session_id := str(_next_id)
	_next_id += 1
	_sessions[session_id] = {
		"pid": int(pipe["pid"]),
		"command": "%s %s" % [godot_exe, " ".join(args)],
		"stdio": pipe.get("stdio", null),
		"stderr": pipe.get("stderr", null),
		"started_unix": Time.get_unix_time_from_system(),
		"stdout_buffer": "",
		"stderr_buffer": "",
		"exit_code": null,
		"project_path": project_path,
	}
	_persist_sessions()
	return {
		"session_id": session_id,
		"pid": int(pipe["pid"]),
		"command": _sessions[session_id]["command"],
	}


# Drain currently-available stdout/stderr from a session. Non-blocking.
# Returns: { "stdout": String, "stderr": String, "running": bool, "exit_code": int|null }
static func drain(session_id: String) -> Dictionary:
	if not _sessions.has(session_id):
		return {"error": "no session with id '%s'" % session_id}
	var s: Dictionary = _sessions[session_id]
	_drain_pipe(s, "stdio", "stdout_buffer")
	var stderr_chunk: String = _drain_pipe(s, "stderr", "stderr_buffer")
	if not stderr_chunk.is_empty():
		RuntimeLogStream.ingest_chunk(session_id, stderr_chunk)
	var running := OS.is_process_running(int(s["pid"]))
	if not running and s["exit_code"] == null:
		# Process exited; capture the exit code if available. Godot's
		# OS API doesn't expose exit codes from execute_with_pipe
		# directly — best we can do is report null and let the caller
		# infer from stderr/stdout content.
		s["exit_code"] = -1
	var out_chunk: String = s["stdout_buffer"]
	var err_chunk: String = s["stderr_buffer"]
	# Reset the buffers so each drain returns only the new content.
	s["stdout_buffer"] = ""
	s["stderr_buffer"] = ""
	return {
		"stdout": out_chunk,
		"stderr": err_chunk,
		"running": running,
		"exit_code": s["exit_code"],
		"pid": int(s["pid"]),
	}


# Non-blocking read: pull whatever bytes the OS has already buffered for
# the pipe FD and stop. get_line() would block on a partially-filled
# buffer (no newline yet) and lock the bridge's main-thread dispatch —
# get_buffer returns immediately with whatever is currently readable.
#
# Caveat: we cap each drain at 64KB. If the running process is spewing
# output faster than the agent drains, lines will accumulate in the OS
# pipe buffer; the next drain picks up the next 64KB chunk.
#
# Returns the just-read chunk (or "" when nothing was available). Callers
# can forward stderr chunks to RuntimeLogStream for structured parsing;
# the stdout chunk is consumed only by the user-facing buffer.
static func _drain_pipe(s: Dictionary, pipe_key: String, buf_key: String) -> String:
	var pipe = s.get(pipe_key, null)
	if pipe == null:
		return ""
	if not (pipe is FileAccess):
		return ""
	const CHUNK_BYTES := 65536
	# get_buffer reads up to N bytes from whatever the OS has ready;
	# returns fewer if the pipe is currently empty (does not block).
	var bytes: PackedByteArray = pipe.get_buffer(CHUNK_BYTES)
	if bytes.is_empty():
		return ""
	var text := bytes.get_string_from_utf8()
	if text.is_empty():
		return ""
	s[buf_key] = String(s[buf_key]) + text
	return text


# Passive pump used by get_runtime_events to refresh the structured stream
# without consuming the user-facing stdout/stderr buffers. Each pipe is
# read once per call (OS pipes are destructive — bytes go into the
# per-session buffer for get_debug_output to consume on its next call,
# AND into RuntimeLogStream for structured parsing).
static func tick_all_sessions() -> void:
	for sid in _sessions.keys():
		var s: Dictionary = _sessions[sid]
		_drain_pipe(s, "stdio", "stdout_buffer")
		var stderr_chunk: String = _drain_pipe(s, "stderr", "stderr_buffer")
		if not stderr_chunk.is_empty():
			RuntimeLogStream.ingest_chunk(String(sid), stderr_chunk)


# Kill a running session. Returns the final drained output + exit info.
static func stop(session_id: String) -> Dictionary:
	if not _sessions.has(session_id):
		return {"error": "no session with id '%s'" % session_id}
	var s: Dictionary = _sessions[session_id]
	var pid: int = int(s["pid"])
	# Final drain before killing so the caller sees any last-second output.
	_drain_pipe(s, "stdio", "stdout_buffer")
	var stderr_chunk: String = _drain_pipe(s, "stderr", "stderr_buffer")
	if not stderr_chunk.is_empty():
		RuntimeLogStream.ingest_chunk(session_id, stderr_chunk)
	# Flush any in-progress error event whose trailing stack frame was the
	# last line of stderr — otherwise it'd sit in the parser forever.
	RuntimeLogStream.flush_session(session_id)
	var was_running := OS.is_process_running(pid)
	if was_running:
		OS.kill(pid)
	s["exit_code"] = 0 if not was_running else -2  # -2 = killed by us
	var final_stdout: String = s["stdout_buffer"]
	var final_stderr: String = s["stderr_buffer"]
	_sessions.erase(session_id)
	_persist_sessions()
	return {
		"pid": pid,
		"stdout": final_stdout,
		"stderr": final_stderr,
		"was_running": was_running,
		"exit_code": s["exit_code"],
	}


static func list_sessions() -> Array:
	var out: Array = []
	for sid in _sessions.keys():
		var s: Dictionary = _sessions[sid]
		out.append({
			"session_id": sid,
			"pid": int(s["pid"]),
			"command": s["command"],
			"running": OS.is_process_running(int(s["pid"])),
			"started_unix": s["started_unix"],
		})
	return out


# Diagnostic accessor for get_runtime_events. Returns aggregate stderr/stdout
# byte counts across all active sessions plus a short tail string so the
# agent can tell whether the bridge captured ANY output even when the
# structured parser came up empty. Empty events with raw_stderr_bytes > 0
# means a parser miss (likely a new Godot prefix); empty events with
# raw_stderr_bytes == 0 means the bytes never reached the bridge (libc
# stderr buffering on the subprocess, no scene errors, etc.).
static func get_buffer_diagnostics(tail_chars: int = 500) -> Dictionary:
	var total_stderr: int = 0
	var total_stdout: int = 0
	var longest_stderr: String = ""
	for sid in _sessions.keys():
		var s: Dictionary = _sessions[sid]
		var stderr_buf: String = String(s.get("stderr_buffer", ""))
		var stdout_buf: String = String(s.get("stdout_buffer", ""))
		total_stderr += stderr_buf.length()
		total_stdout += stdout_buf.length()
		if stderr_buf.length() > longest_stderr.length():
			longest_stderr = stderr_buf
	var tail: String = longest_stderr
	if tail_chars > 0 and tail.length() > tail_chars:
		tail = tail.substr(tail.length() - tail_chars)
	return {
		"raw_stderr_bytes": total_stderr,
		"raw_stdout_bytes": total_stdout,
		"raw_stderr_tail": tail,
	}


# ── Plugin-reload survival ────────────────────────────────────────────────
# Mirror the PID + minimal metadata of currently-tracked sessions to disk so
# a plugin hot-reload (which clears `_sessions`) can detect and kill the
# orphaned children. We don't try to re-attach output capture — the pipe
# FDs are owned by the previous plugin instance and are gone. The goal is
# zombie prevention, not stdout/stderr continuity.

static func _persist_sessions() -> void:
	# Best-effort. A failure here doesn't break the spawn — it just means
	# we'll leak this session if the plugin hot-reloads before stop().
	var dir_path: String = SESSIONS_PERSIST_PATH.get_base_dir()
	var dir_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		push_warning("[GladeKit MCP Bridge] PlaySessionManager: could not create %s (err %d)" % [dir_path, dir_err])
		return
	var snapshot: Array = []
	for sid in _sessions.keys():
		var s: Dictionary = _sessions[sid]
		snapshot.append({
			"session_id": String(sid),
			"pid": int(s.get("pid", 0)),
			"command": String(s.get("command", "")),
			"project_path": String(s.get("project_path", "")),
			"started_unix": float(s.get("started_unix", 0.0)),
		})
	var f := FileAccess.open(SESSIONS_PERSIST_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(snapshot))
	f.close()


# Read the on-disk PID mirror and reap any session that's still running. Call
# once from the WS server's start() before any new sessions can be spawned.
# Returns a list of {pid, killed: bool, project_path} for diagnostics; the
# bridge logs a one-line summary so the user sees what we cleaned up.
static func reap_orphans() -> Array:
	var reaped: Array = []
	if not FileAccess.file_exists(SESSIONS_PERSIST_PATH):
		return reaped
	var f := FileAccess.open(SESSIONS_PERSIST_PATH, FileAccess.READ)
	if f == null:
		return reaped
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Array):
		# Corrupt mirror — wipe it so it doesn't keep tripping us up.
		_clear_persisted()
		return reaped
	for entry in parsed:
		if not (entry is Dictionary):
			continue
		var pid: int = int(entry.get("pid", 0))
		var project_path: String = String(entry.get("project_path", ""))
		if pid <= 0:
			continue
		var was_running := OS.is_process_running(pid)
		var killed := false
		if was_running:
			# OS.kill may fail (permissions, already exited between is_running
			# and kill, etc.); we still report the attempt.
			var kill_err := OS.kill(pid)
			killed = kill_err == OK
		reaped.append({
			"pid": pid,
			"project_path": project_path,
			"was_running": was_running,
			"killed": killed,
		})
	_clear_persisted()
	return reaped


static func _clear_persisted() -> void:
	if not FileAccess.file_exists(SESSIONS_PERSIST_PATH):
		return
	var dir := DirAccess.open(SESSIONS_PERSIST_PATH.get_base_dir())
	if dir == null:
		return
	dir.remove(SESSIONS_PERSIST_PATH.get_file())
