extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Disarms structured runtime-event observation. The ring buffer keeps
# recording errors from any active play sessions; this just tells the
# bridge the caller is no longer interested.
#
# Mirrors Unity's stop_runtime_observation. Read-only — safe in any mode.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const PlayModeObserver = preload("res://addons/com.gladekit.mcp-bridge/services/play_mode_observer.gd")


func _init() -> void:
	tool_name = "stop_runtime_observation"
	requires_edit_mode = false


func execute(_args: Dictionary) -> Dictionary:
	PlayModeObserver.stop_observation()
	return ToolUtils.success(
		"Runtime observation stopped",
		{"observation_active": false},
	)
