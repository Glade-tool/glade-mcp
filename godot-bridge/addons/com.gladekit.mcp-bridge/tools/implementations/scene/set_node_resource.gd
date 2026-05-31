extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Assigns a Resource (loaded from a res:// path) to a Resource-typed property
# on a node in the edited scene. One tool covers every "give this node a
# resource" case instead of a separate assign_* tool per resource kind:
#
#   MeshInstance3D.mesh          ← a Mesh        (.tres / .res / .obj imported)
#   Sprite2D / Sprite3D.texture  ← a Texture2D   (.png / .tres)
#   CollisionShape3D.shape       ← a Shape3D
#   CollisionShape2D.shape       ← a Shape2D
#   AudioStreamPlayer*.stream    ← an AudioStream
#   Camera3D.environment         ← an Environment
#   GeometryInstance3D.material_override ← a Material
#
# Args:
#   node_path:     String (required) — target node in the edited scene.
#   property:      String (required) — the Resource-typed property to set
#                                      (e.g. "mesh", "texture", "shape",
#                                      "stream", "material_override").
#   resource_path: String (required) — res:// path to the resource to load
#                                      and assign. Pass "" or null to CLEAR
#                                      the property (set it to null).
#
# Validation:
#   - node must exist; property must exist on the node and be Resource-typed.
#   - when the property declares an expected resource class via
#     PROPERTY_HINT_RESOURCE_TYPE and that class is a built-in (in ClassDB),
#     the loaded resource must be that class or a subclass — otherwise the
#     call is rejected with the expected type + the node's other
#     resource-typed properties as recovery hints. Custom/script resource
#     classes can't be reliably verified here, so those are accepted (the
#     editor surfaces a real type error on save if genuinely wrong).
#
# Response payload:
#   node_path, property, resource_path (assigned, or null when cleared),
#   resource_type, expected_type, previous_resource_path
#
# For MeshInstance3D *surface* material overrides (per-surface slots), use
# set_material_property's target_node_path/surface args — those go through
# set_surface_override_material(), not a plain named property.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "set_node_resource"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	if not args.has("node_path"):
		return ToolUtils.error("node_path is required")
	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	var node: Node = ToolUtils.find_node_by_path(node_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found" % node_path)

	var property: String = ToolUtils.parse_string_arg(args, "property")
	if property.is_empty():
		return ToolUtils.error("property is required (e.g. 'mesh', 'texture', 'shape', 'stream')")

	var prop_info: Dictionary = _find_property(node, property)
	if prop_info.is_empty():
		return ToolUtils.error_with_solutions(
			"Node '%s' (%s) has no property '%s'" % [node_path, node.get_class(), property],
			[
				"Pick one of this node's resource-typed properties (see resource_properties)",
				"Call get_node_info to inspect the node",
			],
			{"resource_properties": _resource_properties(node)}
		)

	if int(prop_info.get("type", TYPE_NIL)) != TYPE_OBJECT:
		return ToolUtils.error_with_solutions(
			"Property '%s' on %s is not resource-typed" % [property, node.get_class()],
			[
				"set_node_resource only assigns Resource-typed properties",
				"For scalars/vectors use set_node_transform or a script-property tool",
			],
			{"resource_properties": _resource_properties(node)}
		)

	var expected_class: String = String(prop_info.get("hint_string", ""))

	# Capture the previous resource path (if any) for the response / undo hint.
	var prev = node.get(property)
	var prev_path: String = ""
	if prev is Resource and not String((prev as Resource).resource_path).is_empty():
		prev_path = (prev as Resource).resource_path

	# resource_path is required so we never clear a property by accident from a
	# forgotten arg — clearing must be explicit ("" or null).
	if not args.has("resource_path"):
		return ToolUtils.error('resource_path is required (pass "" or null to clear the property)')
	var resource_path: String = ToolUtils.parse_path_arg(args, "resource_path")

	if resource_path.is_empty():
		node.set(property, null)
		return ToolUtils.success("Cleared '%s' on '%s'" % [property, node_path], {
			"node_path": node_path,
			"property": property,
			"resource_path": null,
			"resource_type": "",
			"expected_type": expected_class,
			"previous_resource_path": prev_path,
		})

	if not FileAccess.file_exists(resource_path):
		return ToolUtils.error_with_solutions(
			"Resource does not exist at '%s'" % resource_path,
			[
				"Check the path with find_asset / list_assets",
				"Create it first (create_material, etc.) then assign",
			]
		)

	var res = load(resource_path)
	if not (res is Resource):
		return ToolUtils.error("Resource at '%s' did not load as a Resource" % resource_path)

	# Type check — only enforce against built-in expected classes we can verify
	# via ClassDB. Custom/script resource classes are accepted (can't verify
	# reliably without risking a false reject).
	if not expected_class.is_empty() and ClassDB.class_exists(expected_class):
		if not res.is_class(expected_class):
			return ToolUtils.error_with_solutions(
				"Resource '%s' is %s but property '%s' expects %s" % [resource_path, res.get_class(), property, expected_class],
				[
					"Load a %s resource for this property" % expected_class,
					"Inspect available resources with get_project_info (detailed)",
				],
				{"expected_type": expected_class, "got_type": res.get_class()}
			)

	node.set(property, res)
	return ToolUtils.success("Assigned %s to '%s.%s'" % [res.get_class(), node_path, property], {
		"node_path": node_path,
		"property": property,
		"resource_path": resource_path,
		"resource_type": res.get_class(),
		"expected_type": expected_class,
		"previous_resource_path": prev_path,
	})


# Returns the property-list entry whose name matches, or {} if absent.
func _find_property(node: Node, property_name: String) -> Dictionary:
	for p in node.get_property_list():
		if String(p.get("name", "")) == property_name:
			return p
	return {}


# Lists the node's Resource-typed properties as {name, type} so a wrong-property
# error can tell the agent exactly what it CAN assign here.
func _resource_properties(node: Node) -> Array:
	var out: Array = []
	for p in node.get_property_list():
		if int(p.get("type", TYPE_NIL)) != TYPE_OBJECT:
			continue
		if int(p.get("hint", 0)) != PROPERTY_HINT_RESOURCE_TYPE:
			continue
		out.append({
			"name": String(p.get("name", "")),
			"type": String(p.get("hint_string", "")),
		})
	return out
