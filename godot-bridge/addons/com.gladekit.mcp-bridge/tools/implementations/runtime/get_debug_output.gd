extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Drains stdout/stderr from a running play session (non-blocking).
# Returns only NEW output since the last drain — repeated calls don't
# return the same lines twice.
#
# Args:
#   session_id: String (required) — value returned from run_project.
#
# Response payload:
#   stdout, stderr: String — newly available text
#   running:        bool
#   exit_code:      int|null — null while running
#   pid:            int

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const PlaySessionManager = preload("res://addons/com.gladekit.mcp-bridge/services/play_session_manager.gd")


func _init() -> void:
	tool_name = "get_debug_output"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var session_id: String = ToolUtils.parse_string_arg(args, "session_id")
	if session_id.is_empty():
		return ToolUtils.error("session_id is required")
	var result := PlaySessionManager.drain(session_id)
	if result.has("error"):
		return ToolUtils.error(result["error"])
	return ToolUtils.success(
		"Drained session %s (running=%s)" % [session_id, str(result["running"])],
		{
			"stdout": result["stdout"],
			"stderr": result["stderr"],
			"running": result["running"],
			"exit_code": result["exit_code"],
			"pid": int(result["pid"]),
		}
	)
