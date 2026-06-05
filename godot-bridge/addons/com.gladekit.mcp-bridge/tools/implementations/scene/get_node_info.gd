extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Returns metadata about a single node: name, class, attached script,
# children count, owner, groups, and (for Node2D/Node3D) transform.
# Read-only — safe during play mode.
#
# Args:
#   node_path: String (required) — scene-relative path ("Player" or
#              "Player/Sprite") or absolute ("/root/Main/Player"). Empty/"."
#              resolves to the edited scene root.
#   include_properties: bool (default false) — when true, also return a
#              `properties` dict of the node's settable scalar/vector/color/bool
#              values (the names set_node_property can write). Use this to
#              discover what's configurable and read current values before a set.
#
# Response payload:
#   name, type, path, script_path (optional), child_count,
#   children: [String] (immediate children names),
#   groups: [String],
#   position / rotation / scale: "x,y,z" (Node3D only)
#   position2d / rotation2d / scale2d: serialized (Node2D only)
#   properties: {name: value} (only when include_properties=true)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SetNodeProperty = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/set_node_property.gd")

# Cap on echoed property values — some nodes expose 150+ properties.
const _MAX_PROPERTIES := 80


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

	if ToolUtils.parse_bool_arg(args, "include_properties", false):
		info["properties"] = _collect_properties(node)

	return ToolUtils.success("Read info for '%s'" % node_path, info)


# Returns the node's settable, non-Resource property values as {name: value},
# matching exactly the set set_node_property can write — so the agent can read,
# then set, without guessing names. Resource (Object) properties are skipped
# here (those go through set_node_resource).
func _collect_properties(node: Node) -> Dictionary:
	var out: Dictionary = {}
	for p in node.get_property_list():
		var t: int = int(p.get("type", TYPE_NIL))
		if t == TYPE_NIL or t == TYPE_OBJECT:
			continue
		var usage: int = int(p.get("usage", 0))
		if (usage & (PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR)) == 0:
			continue
		var name: String = String(p.get("name", ""))
		if name.is_empty():
			continue
		out[name] = SetNodeProperty._serialize(node.get(name))
		if out.size() >= _MAX_PROPERTIES:
			break
	return out
