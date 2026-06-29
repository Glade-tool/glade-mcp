extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Finds every .tscn scene that references a resource (a .gd script or a .tscn
# scene) via an [ext_resource ... path="res://..."] entry — the wiring counterpart
# to find_references. Where find_references covers code, this covers SCENE wiring:
# which scenes attach a script to a node, or instance a scene as a sub-scene. That
# wiring lives in .tscn data, not in code, so find_references can't see it. Use it
# to find the blast radius before renaming/moving/deleting a script or scene. Read-only.
#
# Args:
#   resource_path: String (required) — res:// path to the .gd or .tscn to trace.
#   max_results:   int (default 60, clamped 1..200) — max referencing scenes.
#
# Response payload:
#   resource_path: String
#   count:         int  — number of scenes referencing the resource
#   truncated:     bool — true if the scan hit max_results
#   usages:        [ { scene:String, ref_type:String, line:int } ]
#                  ref_type is the ext_resource type (e.g. "Script", "PackedScene")
#                  when present, else "" — tells script-attachment from scene-instancing.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const DEFAULT_MAX := 60
const HARD_CAP := 200


func _init() -> void:
	tool_name = "find_scene_usages"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var resource_path: String = ToolUtils.parse_path_arg(args, "resource_path")
	if resource_path.is_empty():
		return ToolUtils.error("resource_path is required")

	var max_results: int = clamp(ToolUtils.parse_int_arg(args, "max_results", DEFAULT_MAX), 1, HARD_CAP)

	# Match the exact quoted path so res://Player.gd doesn't match res://Player.gd.uid
	# or a longer path that merely contains it.
	var needle := 'path="%s"' % resource_path

	var usages: Array = []
	var truncated := false

	var stack: Array = ["res://"]
	while not stack.is_empty():
		var dir_path: String = stack.pop_back()
		if dir_path.begins_with("res://addons"):
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
			elif entry.ends_with(".tscn"):
				var hit := _scan_scene(entry_path, needle)
				if not hit.is_empty():
					usages.append(hit)
					if usages.size() >= max_results:
						truncated = true
						break
		dir.list_dir_end()
		if truncated:
			break

	usages.sort_custom(func(a, b): return a["scene"] < b["scene"])

	var msg: String
	if usages.is_empty():
		msg = "No scene references '%s'." % resource_path
	else:
		msg = "Found %d scene(s) referencing '%s'." % [usages.size(), resource_path]

	return ToolUtils.success(msg, {
		"resource_path": resource_path,
		"count": usages.size(),
		"truncated": truncated,
		"usages": usages,
	})


# Returns the first ext_resource match in the scene as {scene, ref_type, line},
# or {} if the scene does not reference the resource. One entry per scene is
# enough for a blast-radius answer.
func _scan_scene(path: String, needle: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var raw := file.get_as_text()
	file.close()

	if not raw.contains(needle):
		return {}

	var lines: PackedStringArray = raw.split("\n", true)
	for li in lines.size():
		if not lines[li].contains(needle):
			continue
		return {
			"scene": path,
			"ref_type": _extract_attr(lines[li], "type"),
			"line": li + 1,
		}
	return {}


# Pulls a double-quoted attribute value (e.g. type="Script" -> "Script") out of a
# .tscn line; returns "" when the attribute is absent.
func _extract_attr(line: String, attr: String) -> String:
	var key := '%s="' % attr
	var start := line.find(key)
	if start < 0:
		return ""
	start += key.length()
	var end := line.find('"', start)
	if end < 0:
		return ""
	return line.substr(start, end - start)
