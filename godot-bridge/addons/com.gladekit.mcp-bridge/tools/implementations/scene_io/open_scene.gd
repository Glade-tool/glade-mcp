extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Opens an existing .tscn scene in the editor and makes it the edited scene.
#
# Args:
#   path: String (required) — res:// path to a .tscn or .scn.
#
# Response payload:
#   path, previous_scene_path (the scene that was edited before, if any)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "open_scene"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var path: String = ToolUtils.parse_path_arg(args, "path")
	if path.is_empty():
		return ToolUtils.error("path is required")
	if not FileAccess.file_exists(path):
		return ToolUtils.error_with_solutions(
			"Scene does not exist at '%s'" % path,
			["Call create_scene to scaffold a new scene", "Or check the project file tree with find_scripts / list_assets"]
		)
	var ext := path.get_extension().to_lower()
	if ext != "tscn" and ext != "scn":
		return ToolUtils.error("path must be a .tscn or .scn (got .%s)" % ext)

	var prev := EditorInterface.get_edited_scene_root()
	var prev_path: String = prev.scene_file_path if prev != null else ""

	EditorInterface.open_scene_from_path(path)

	return ToolUtils.success("Opened scene '%s'" % path, {
		"path": path,
		"previous_scene_path": prev_path,
	})
