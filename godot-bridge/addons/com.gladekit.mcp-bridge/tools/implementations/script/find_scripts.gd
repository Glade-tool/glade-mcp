extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Walks the project filesystem for .gd files matching a name pattern. Skips
# the addons/ directory by default (the agent rarely wants to read addon
# internals; including them generates noise on every search). Read-only.
#
# Args:
#   name_contains:  String — case-insensitive substring on the filename.
#                            Empty matches all .gd files.
#   max_results:    int (default 20, clamped 1..200)
#   include_addons: bool (default false) — search inside res://addons/ too.
#
# Response payload:
#   scripts:   [String] — res:// paths, sorted
#   count:     int
#   truncated: bool

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const DEFAULT_MAX := 20
const HARD_CAP := 200


func _init() -> void:
	tool_name = "find_scripts"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var name_contains: String = ToolUtils.parse_string_arg(args, "name_contains").to_lower()
	var max_results: int = clamp(ToolUtils.parse_int_arg(args, "max_results", DEFAULT_MAX), 1, HARD_CAP)
	var include_addons: bool = ToolUtils.parse_bool_arg(args, "include_addons", false)

	var results: Array = []
	var truncated := false

	# Use a manual stack instead of recursion so very deep project trees don't
	# blow the GDScript call stack.
	var stack: Array = ["res://"]
	while not stack.is_empty():
		var dir_path: String = stack.pop_back()
		if not include_addons and dir_path.begins_with("res://addons"):
			continue
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		dir.list_dir_begin()
		while true:
			var entry := dir.get_next()
			if entry.is_empty():
				break
			if entry.begins_with("."):
				continue
			var entry_path: String = dir_path.path_join(entry)
			if dir.current_is_dir():
				stack.push_back(entry_path)
			elif entry.ends_with(".gd"):
				if name_contains.is_empty() or entry.to_lower().contains(name_contains):
					results.append(entry_path)
					if results.size() >= max_results:
						truncated = true
						break
		dir.list_dir_end()
		if truncated:
			break

	results.sort()
	return ToolUtils.success("Found %d script(s)" % results.size(), {
		"scripts": results,
		"count": results.size(),
		"truncated": truncated,
	})
