extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Instantiates a PackedScene (.tscn) into the edited scene tree. The Godot
# equivalent of Unity's instantiate_prefab.
#
# Args:
#   scene_path:  String (required) — res:// path to a .tscn or .scn.
#   parent_path: String — scene-relative parent. Default: scene root.
#   name:        String — name for the instantiated root. Default: the
#                         PackedScene's root name.
#   position:    "x,y,z" — initial position for Node3D-rooted scenes.
#
# Response payload:
#   node_path, scene_path, type

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "instantiate_scene"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var scene_path: String = ToolUtils.parse_path_arg(args, "scene_path")
	if scene_path.is_empty():
		return ToolUtils.error("scene_path is required")
	if not FileAccess.file_exists(scene_path):
		return ToolUtils.error("Scene file '%s' does not exist" % scene_path)

	var edited_root: Node = EditorInterface.get_edited_scene_root()
	if edited_root == null:
		return ToolUtils.error("No scene is currently open in the editor")

	var packed = load(scene_path)
	if not (packed is PackedScene):
		return ToolUtils.error("Resource at '%s' is not a PackedScene (got %s)" % [scene_path, typeof(packed)])

	var instance := (packed as PackedScene).instantiate()
	if instance == null:
		return ToolUtils.error("PackedScene.instantiate returned null for '%s'" % scene_path)
	if not (instance is Node):
		return ToolUtils.error("Instantiated resource is not a Node")

	var requested_name: String = ToolUtils.parse_string_arg(args, "name")
	if not requested_name.is_empty():
		instance.name = requested_name

	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else edited_root
	if parent == null:
		instance.free()
		return ToolUtils.error("Parent '%s' not found" % parent_path)

	parent.add_child(instance)
	# `owner = edited_root` makes the instance save with the scene; we also
	# leave the PackedScene reference intact so this remains a scene
	# instance (visible in the editor with the chain-link icon).
	instance.owner = edited_root

	if args.has("position") and instance is Node3D:
		(instance as Node3D).position = ToolUtils.parse_vector3_arg(args, "position", Vector3.ZERO)

	return ToolUtils.success("Instantiated '%s'" % scene_path, {
		"node_path": ToolUtils.node_relative_path(instance),
		"scene_path": scene_path,
		"type": instance.get_class(),
	})
