extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Kills a play session started by run_project. Returns the final drained
# stdout/stderr so the agent can examine any last-second output.
#
# Args:
#   session_id: String (required) — value returned from run_project.
#
# Response payload:
#   pid, stdout, stderr, was_running, exit_code

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const PlaySessionManager = preload("res://addons/com.gladekit.mcp-bridge/services/play_session_manager.gd")


func _init() -> void:
	tool_name = "stop_project"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var session_id: String = ToolUtils.parse_string_arg(args, "session_id")
	if session_id.is_empty():
		return ToolUtils.error_with_solutions(
			"session_id is required",
			["Pass the session_id returned by run_project", "Or use the bridge's diagnostics endpoint to list active sessions"]
		)
	var result := PlaySessionManager.stop(session_id)
	if result.has("error"):
		return ToolUtils.error(result["error"])
	return ToolUtils.success("Stopped session %s (pid %d)" % [session_id, int(result["pid"])], {
		"pid": int(result["pid"]),
		"stdout": result["stdout"],
		"stderr": result["stderr"],
		"was_running": result["was_running"],
		"exit_code": result["exit_code"],
	})
