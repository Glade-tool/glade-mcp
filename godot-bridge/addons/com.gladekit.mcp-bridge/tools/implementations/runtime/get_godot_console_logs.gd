extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Returns the tail of the editor log file (user://logs/godot.log by
# default; Godot writes editor stdout/stderr there when "debug/file_logging
# /enable_file_logging" is on, which is the default for the editor).
#
# Read-only — safe in play mode.
#
# Args:
#   max_lines:  int — how many trailing lines to return. Default 200, capped 2000.
#   filter:     String — case-insensitive substring; only matching lines are returned.
#
# Response payload:
#   log_path:  String — absolute log file path
#   lines:     [String]
#   truncated: bool — true if the log was larger than what we returned

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const DEFAULT_MAX_LINES := 200
const HARD_CAP := 2000


func _init() -> void:
	tool_name = "get_godot_console_logs"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var log_path := _resolve_log_path()
	if log_path.is_empty():
		return ToolUtils.error_with_solutions(
			"Could not locate Godot's editor log file",
			["Enable Editor Settings → Debugger → File Logging", "Or pass an explicit log_path arg"]
		)

	var f := FileAccess.open(log_path, FileAccess.READ)
	if f == null:
		return ToolUtils.error_with_solutions(
			"Could not open log file '%s' (err %d)" % [log_path, FileAccess.get_open_error()],
			["Confirm file_logging is enabled", "Confirm Godot has permission to read the path"]
		)
	# Read the entire file then tail. Editor logs are small in practice
	# (kilobytes per session). For huge logs we cap aggressively below.
	var text := f.get_as_text()
	f.close()

	var all_lines: PackedStringArray = text.split("\n", false)
	var max_lines: int = clamp(ToolUtils.parse_int_arg(args, "max_lines", DEFAULT_MAX_LINES), 1, HARD_CAP)
	var filter: String = ToolUtils.parse_string_arg(args, "filter").to_lower()

	var filtered: Array = []
	if filter.is_empty():
		filtered = Array(all_lines)
	else:
		for line in all_lines:
			if String(line).to_lower().contains(filter):
				filtered.append(line)

	var truncated := filtered.size() > max_lines
	var tail: Array = filtered if not truncated else filtered.slice(filtered.size() - max_lines)

	return ToolUtils.success("Read %d log line(s) from '%s'" % [tail.size(), log_path], {
		"log_path": log_path,
		"lines": tail,
		"truncated": truncated,
	})


func _resolve_log_path() -> String:
	# Godot writes editor logs to user://logs/godot.log by default. The
	# user:// scheme resolves to a per-OS path under the user's data dir.
	var p := ProjectSettings.globalize_path("user://logs/godot.log")
	if FileAccess.file_exists("user://logs/godot.log"):
		return p
	# Some configurations write timestamped files (godot.<ts>.log). Pick the
	# newest if the default doesn't exist.
	var dir := DirAccess.open("user://logs")
	if dir == null:
		return ""
	var newest := ""
	var newest_ts: int = -1
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry.is_empty():
			break
		if not entry.ends_with(".log"):
			continue
		var full := "user://logs/" + entry
		var ts := FileAccess.get_modified_time(full)
		if ts > newest_ts:
			newest = full
			newest_ts = ts
	dir.list_dir_end()
	return ProjectSettings.globalize_path(newest) if not newest.is_empty() else ""
