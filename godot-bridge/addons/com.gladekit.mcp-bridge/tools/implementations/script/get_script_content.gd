extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Reads the contents of a .gd script file. Read-only — safe in play mode.
#
# Paginated to keep large scripts from flooding the agent's context window.
# Defaults return the first 500 lines and echo `total_lines` + `truncated`
# so the agent knows whether to request more. Non-agent callers that want
# the whole file in one shot can pass `max_lines=5000` (the hard cap).
#
# Args:
#   script_path: String (required) — res:// path.
#   start_line:  int — 1-indexed start, default 1.
#   end_line:    int — 1-indexed inclusive end, default 0 = "until EOF
#                      or max_lines, whichever is smaller".
#   max_lines:   int — cap on lines returned, default 500, clamped 1..5000.
#
# Response payload:
#   script_path:  String — normalized res:// path
#   content:      String — newline-joined slice
#   bytes:        int    — byte length of `content`
#   start_line:   int    — actual starting line in `content` (1-indexed)
#   end_line:     int    — actual ending line in `content` (1-indexed)
#   total_lines:  int    — total lines in the file
#   truncated:    bool   — true if there are unreturned lines past end_line

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const DEFAULT_MAX_LINES := 500
const HARD_CAP_LINES := 5000


func _init() -> void:
	tool_name = "get_script_content"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var script_path: String = ToolUtils.parse_path_arg(args, "script_path")
	if script_path.is_empty():
		return ToolUtils.error("script_path is required")

	if not FileAccess.file_exists(script_path):
		return ToolUtils.error("File does not exist at '%s'" % script_path)

	var file := FileAccess.open(script_path, FileAccess.READ)
	if file == null:
		return ToolUtils.error("Could not open '%s' for reading (FileAccess error %d)" % [script_path, FileAccess.get_open_error()])
	var raw := file.get_as_text()
	file.close()

	# Split deliberately keeps empty trailing entries so total_lines reflects
	# what a human would see in an editor: a trailing newline yields one extra
	# empty line at the end.
	var all_lines: PackedStringArray = raw.split("\n", true)
	var total_lines: int = all_lines.size()

	var start_line: int = max(1, ToolUtils.parse_int_arg(args, "start_line", 1))
	var requested_max: int = ToolUtils.parse_int_arg(args, "max_lines", DEFAULT_MAX_LINES)
	if requested_max <= 0:
		requested_max = DEFAULT_MAX_LINES
	var max_lines: int = clamp(requested_max, 1, HARD_CAP_LINES)

	var requested_end: int = ToolUtils.parse_int_arg(args, "end_line", 0)
	# end_line=0 means "until EOF"; otherwise treat as inclusive 1-indexed end.
	var end_line: int
	if requested_end <= 0:
		end_line = total_lines
	else:
		end_line = min(requested_end, total_lines)

	if start_line > total_lines:
		# Past EOF — return empty content with diagnostics so the agent can
		# correct its next call without a second probe.
		return ToolUtils.success(
			"start_line %d past EOF (total_lines=%d)" % [start_line, total_lines],
			{
				"script_path": script_path,
				"content": "",
				"bytes": 0,
				"start_line": start_line,
				"end_line": start_line,
				"total_lines": total_lines,
				"truncated": false,
			}
		)

	# Cap the window by max_lines starting from start_line.
	var cap_end: int = start_line + max_lines - 1
	if cap_end < end_line:
		end_line = cap_end

	var slice_count: int = end_line - start_line + 1
	var sliced: PackedStringArray = all_lines.slice(start_line - 1, start_line - 1 + slice_count)
	var content := "\n".join(sliced)
	var truncated: bool = end_line < total_lines

	var msg: String
	if truncated:
		msg = "Read lines %d-%d of %d (truncated — pass start_line=%d to continue)" % [
			start_line, end_line, total_lines, end_line + 1
		]
	else:
		msg = "Read %d line(s) of '%s'" % [slice_count, script_path]

	return ToolUtils.success(msg, {
		"script_path": script_path,
		"content": content,
		"bytes": content.length(),
		"start_line": start_line,
		"end_line": end_line,
		"total_lines": total_lines,
		"truncated": truncated,
	})
