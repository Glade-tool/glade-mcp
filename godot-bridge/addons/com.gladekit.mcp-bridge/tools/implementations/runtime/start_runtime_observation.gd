extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Arms structured runtime-event observation. Snapshots the current
# RuntimeLogStream cursor so the first get_runtime_events poll returns only
# events from this point forward — arming should not retroactively surface
# a 10-minute-old error.
#
# Idempotent: re-arming refreshes the baseline cursor. Useful after a
# reconnect when the caller wants a fresh starting point.
#
# Mirrors Unity's start_runtime_observation. The Godot equivalent doesn't
# need an editor-side play-mode-transition callback because the play session
# runs as a separate process (PlaySessionManager) — "is playing" is a
# question we answer by inspecting active sessions at query time.
#
# Read-only — safe to call in any mode. Composable with run_project /
# get_debug_output (those tools keep their existing delta-of-stdout semantics;
# runtime events are surfaced through this separate structured stream).
#
# Response payload:
#   observation_active: bool — true after this call
#   start_cursor:       int  — events with cursor > this are "new" to the caller
#   ring_buffer_size:   int  — events currently buffered (informational)
#   is_playing:         bool — true if any PlaySessionManager session is running

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const PlayModeObserver = preload("res://addons/com.gladekit.mcp-bridge/services/play_mode_observer.gd")
const RuntimeLogStream = preload("res://addons/com.gladekit.mcp-bridge/services/runtime_log_stream.gd")
const PlaySessionManager = preload("res://addons/com.gladekit.mcp-bridge/services/play_session_manager.gd")


func _init() -> void:
	tool_name = "start_runtime_observation"
	requires_edit_mode = false


func execute(_args: Dictionary) -> Dictionary:
	# Pump active sessions before snapshotting so any errors that landed
	# between the agent's last poll and this re-arm are reflected in the
	# baseline cursor (not surfaced as "new" on the next get_runtime_events).
	PlaySessionManager.tick_all_sessions()
	PlayModeObserver.start_observation()

	var is_playing := false
	for s in PlaySessionManager.list_sessions():
		if bool(s.get("running", false)):
			is_playing = true
			break

	return ToolUtils.success(
		"Runtime observation started",
		{
			"observation_active": true,
			"start_cursor": PlayModeObserver.observation_start_cursor(),
			"ring_buffer_size": RuntimeLogStream.current_size(),
			"is_playing": is_playing,
		}
	)
