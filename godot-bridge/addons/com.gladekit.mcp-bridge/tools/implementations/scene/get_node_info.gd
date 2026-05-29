extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Returns metadata about a single node: name, class, attached script,
# children count, owner, groups, and (for Node2D/Node3D) transform.
# Read-only — safe during play mode.
#
# Args:
#   node_path: String (required) — scene-relative path ("Player" or
#              "Player/Sprite") or absolute ("/root/Main/Player"). Empty/"."
#              resolves to the edited scene root.
#
# Response payload:
#   name, type, path, script_path (optional), child_count,
#   children: [String] (immediate children names),
#   groups: [String],
#   position / rotation / scale: "x,y,z" (Node3D only)
#   position2d / rotation2d / scale2d: serialized (Node2D only)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "get_node_info"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	if not args.has("node_path"):
		return ToolUtils.error("node_path is required")
	var node: Node = ToolUtils.find_node_by_path(node_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found in edited scene" % node_path)

	var children: Array = []
	for child in node.get_children():
		children.append(String(child.name))

	var info: Dictionary = {
		"name": String(node.name),
		"type": node.get_class(),
		"path": String(node.get_path()),
		"child_count": node.get_child_count(),
		"children": children,
		"groups": node.get_groups(),
	}

	var script = node.get_script()
	if script != null and script.resource_path != "":
		info["script_path"] = script.resource_path

	if node is Node3D:
		var n3: Node3D = node
		info["position"] = ToolUtils.serialize_vector3(n3.position)
		info["rotation"] = ToolUtils.serialize_vector3(n3.rotation_degrees)
		info["scale"] = ToolUtils.serialize_vector3(n3.scale)
	elif node is Node2D:
		var n2: Node2D = node
		info["position2d"] = "%s,%s" % [n2.position.x, n2.position.y]
		info["rotation2d"] = n2.rotation_degrees
		info["scale2d"] = "%s,%s" % [n2.scale.x, n2.scale.y]

	return ToolUtils.success("Read info for '%s'" % node_path, info)
