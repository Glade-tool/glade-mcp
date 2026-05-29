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

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

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
	_drain_pipe(s, "stderr", "stderr_buffer")
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
static func _drain_pipe(s: Dictionary, pipe_key: String, buf_key: String) -> void:
	var pipe = s.get(pipe_key, null)
	if pipe == null:
		return
	if not (pipe is FileAccess):
		return
	const CHUNK_BYTES := 65536
	# get_buffer reads up to N bytes from whatever the OS has ready;
	# returns fewer if the pipe is currently empty (does not block).
	var bytes: PackedByteArray = pipe.get_buffer(CHUNK_BYTES)
	if bytes.is_empty():
		return
	var text := bytes.get_string_from_utf8()
	if text.is_empty():
		return
	s[buf_key] = String(s[buf_key]) + text


# Kill a running session. Returns the final drained output + exit info.
static func stop(session_id: String) -> Dictionary:
	if not _sessions.has(session_id):
		return {"error": "no session with id '%s'" % session_id}
	var s: Dictionary = _sessions[session_id]
	var pid: int = int(s["pid"])
	# Final drain before killing so the caller sees any last-second output.
	_drain_pipe(s, "stdio", "stdout_buffer")
	_drain_pipe(s, "stderr", "stderr_buffer")
	var was_running := OS.is_process_running(pid)
	if was_running:
		OS.kill(pid)
	s["exit_code"] = 0 if not was_running else -2  # -2 = killed by us
	var final_stdout: String = s["stdout_buffer"]
	var final_stderr: String = s["stderr_buffer"]
	_sessions.erase(session_id)
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
