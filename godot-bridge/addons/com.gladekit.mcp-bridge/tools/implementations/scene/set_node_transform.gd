extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Sets position, rotation, and/or scale on a Node3D or Node2D. Each
# component is independent — omitting an arg leaves that component
# unchanged. Rotation values are in degrees (Euler for Node3D).
#
# Args:
#   node_path: String (required) — target node.
#   space:     String — "local" (default) or "global".
#   position:  "x,y,z" | [x,y,z] | {x,y,z} — Node3D: Vector3.
#                                            Node2D: only x,y are used.
#   rotation:  "x,y,z" | float — Node3D: Vector3 Euler degrees.
#                                Node2D: scalar rotation_degrees.
#   scale:     same as position.
#   operation: "set" (default) | "add" | "multiply" — per-component.
#
# Response payload:
#   previous_state: {position, rotation, scale, space} — pre-update values

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "set_node_transform"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	if not args.has("node_path"):
		return ToolUtils.error("node_path is required")
	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	var node: Node = ToolUtils.find_node_by_path(node_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found" % node_path)

	# At least one transform component must be present — a call with only
	# node_path silently mutates nothing, which makes the agent believe
	# the transform was set and then act on stale values. Refuse instead.
	if not (args.has("position") or args.has("rotation") or args.has("scale")):
		return ToolUtils.error_with_solutions(
			"set_node_transform needs at least one of position, rotation, or scale",
			[
				"Pass position as 'x,y,z' (or [x,y,z]) to move the node",
				"Pass rotation as 'x,y,z' Euler degrees (or scalar degrees for 2D)",
				"Pass scale as 'x,y,z' (1,1,1 = no scaling)",
				"To inspect the current transform, call get_node_info instead",
			]
		)

	var space: String = ToolUtils.parse_string_arg(args, "space", "local").to_lower()
	if space != "local" and space != "global":
		return ToolUtils.error("space must be 'local' or 'global' (got '%s')" % space)
	var is_global: bool = space == "global"
	var operation: String = ToolUtils.parse_string_arg(args, "operation", "set").to_lower()

	if node is Node3D:
		return _apply_3d(node, args, is_global, operation, node_path)
	if node is Node2D:
		return _apply_2d(node, args, is_global, operation, node_path)
	return ToolUtils.error("Node '%s' is %s — transforms only apply to Node3D / Node2D" % [node_path, node.get_class()])


func _apply_3d(n: Node3D, args: Dictionary, is_global: bool, operation: String, node_path: String) -> Dictionary:
	var prev_pos: Vector3 = n.global_position if is_global else n.position
	var prev_rot_deg: Vector3 = n.global_rotation_degrees if is_global else n.rotation_degrees
	var prev_scale: Vector3 = n.scale  # scale is always local in Godot

	if args.has("position"):
		var p: Vector3 = ToolUtils.parse_vector3_arg(args, "position", prev_pos)
		var next := _combine_vec(prev_pos, p, operation)
		if is_global:
			n.global_position = next
		else:
			n.position = next

	if args.has("rotation"):
		var r: Vector3 = ToolUtils.parse_vector3_arg(args, "rotation", prev_rot_deg)
		var next_r := _combine_vec(prev_rot_deg, r, operation)
		if is_global:
			n.global_rotation_degrees = next_r
		else:
			n.rotation_degrees = next_r

	if args.has("scale"):
		var s: Vector3 = ToolUtils.parse_vector3_arg(args, "scale", prev_scale)
		n.scale = _combine_vec(prev_scale, s, operation)

	return ToolUtils.success("Updated transform on '%s' (space=%s, op=%s)" % [node_path, ("global" if is_global else "local"), operation], {
		"previous_state": {
			"position": ToolUtils.serialize_vector3(prev_pos),
			"rotation": ToolUtils.serialize_vector3(prev_rot_deg),
			"scale": ToolUtils.serialize_vector3(prev_scale),
			"space": ("global" if is_global else "local"),
		},
	})


func _apply_2d(n: Node2D, args: Dictionary, is_global: bool, operation: String, node_path: String) -> Dictionary:
	var prev_pos: Vector2 = n.global_position if is_global else n.position
	var prev_rot_deg: float = n.global_rotation_degrees if is_global else n.rotation_degrees
	var prev_scale: Vector2 = n.scale

	if args.has("position"):
		var pv: Vector3 = ToolUtils.parse_vector3_arg(args, "position", Vector3(prev_pos.x, prev_pos.y, 0.0))
		var combined := _combine_vec(Vector3(prev_pos.x, prev_pos.y, 0.0), pv, operation)
		var next := Vector2(combined.x, combined.y)
		if is_global:
			n.global_position = next
		else:
			n.position = next

	if args.has("rotation"):
		var r_in = args["rotation"]
		var r_val: float = prev_rot_deg
		if r_in is float or r_in is int:
			r_val = float(r_in)
		elif r_in is String and (r_in as String).strip_edges().is_valid_float():
			r_val = float(r_in)
		else:
			# Accept vec but use x.
			var v := ToolUtils.parse_vector3_arg(args, "rotation", Vector3(prev_rot_deg, 0, 0))
			r_val = v.x
		var combined_r: float = prev_rot_deg
		match operation:
			"add":
				combined_r = prev_rot_deg + r_val
			"multiply":
				combined_r = prev_rot_deg * r_val
			_:
				combined_r = r_val
		if is_global:
			n.global_rotation_degrees = combined_r
		else:
			n.rotation_degrees = combined_r

	if args.has("scale"):
		var sv: Vector3 = ToolUtils.parse_vector3_arg(args, "scale", Vector3(prev_scale.x, prev_scale.y, 1.0))
		var combined_s := _combine_vec(Vector3(prev_scale.x, prev_scale.y, 1.0), sv, operation)
		n.scale = Vector2(combined_s.x, combined_s.y)

	return ToolUtils.success("Updated transform on '%s' (space=%s, op=%s)" % [node_path, ("global" if is_global else "local"), operation], {
		"previous_state": {
			"position": "%s,%s,0" % [prev_pos.x, prev_pos.y],
			"rotation": "%s,0,0" % prev_rot_deg,
			"scale": "%s,%s,1" % [prev_scale.x, prev_scale.y],
			"space": ("global" if is_global else "local"),
		},
	})


func _combine_vec(current: Vector3, v: Vector3, operation: String) -> Vector3:
	match operation:
		"add":
			return current + v
		"multiply":
			return Vector3(current.x * v.x, current.y * v.y, current.z * v.z)
		_:
			return v
