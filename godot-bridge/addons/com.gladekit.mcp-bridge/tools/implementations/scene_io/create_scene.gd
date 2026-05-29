extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates a new .tscn scene file with a single root node and opens it
# in the editor. Refuses to overwrite an existing scene file.
#
# Args:
#   path:      String (required) — res:// path. Auto-appends .tscn.
#   root_type: String — class for the scene root. Default: "Node3D".
#                       Anything ClassDB.can_instantiate() accepts works.
#   root_name: String — name of the root node. Default: derived from root_type.
#   open:      bool — open the new scene immediately. Default: true.
#
# Response payload:
#   path, root_type, root_name, opened (bool)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const DemoAssetsGuard = preload("res://addons/com.gladekit.mcp-bridge/services/demo_assets_guard.gd")


func _init() -> void:
	tool_name = "create_scene"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var path: String = ToolUtils.parse_path_arg(args, "path")
	if path.is_empty():
		return ToolUtils.error("path is required")
	if path.get_extension().is_empty():
		path += ".tscn"

	var ext := path.get_extension().to_lower()
	if ext != "tscn" and ext != "scn":
		return ToolUtils.error("path must end in .tscn or .scn (got .%s)" % ext)

	var guard_err := DemoAssetsGuard.check_write(path)
	if not guard_err.is_empty():
		return ToolUtils.error(guard_err)

	if FileAccess.file_exists(path):
		return ToolUtils.error_with_solutions(
			"Scene already exists at '%s'" % path,
			["Call open_scene to load the existing scene", "Or pick a different path"]
		)

	var root_type: String = ToolUtils.parse_string_arg(args, "root_type", "Node3D")
	var inst_result: Dictionary = ToolUtils.safe_instantiate_class(root_type)
	if inst_result["instance"] == null:
		return ToolUtils.error("Could not create root node of type '%s': %s" % [root_type, inst_result["error"]])
	var root_node = inst_result["instance"]
	if not (root_node is Node):
		return ToolUtils.error("Type '%s' did not instantiate to a Node" % root_type)
	root_node.name = ToolUtils.parse_string_arg(args, "root_name", root_type)

	var dir_path := path.get_base_dir()
	if not dir_path.is_empty():
		var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
		if err != OK and err != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (err %d)" % [dir_path, err])

	var packed := PackedScene.new()
	var pack_err := packed.pack(root_node)
	if pack_err != OK:
		root_node.free()
		return ToolUtils.error("PackedScene.pack failed for root '%s' (err %d)" % [root_type, pack_err])
	var save_err := ResourceSaver.save(packed, path)
	root_node.free()
	if save_err != OK:
		return ToolUtils.error("ResourceSaver.save failed for '%s' (err %d)" % [path, save_err])

	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(path)

	var should_open: bool = ToolUtils.parse_bool_arg(args, "open", true)
	if should_open:
		EditorInterface.open_scene_from_path(path)

	return ToolUtils.success("Created scene at '%s'" % path, {
		"path": path,
		"root_type": root_type,
		"root_name": ToolUtils.parse_string_arg(args, "root_name", root_type),
		"opened": should_open,
	})
