extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Sets a Control's size and/or custom_minimum_size. Pass only the dimensions
# you want to change — omitted args leave the current value alone.
#
# Note: `size` has no effect on a Control whose anchors stretch it across its
# parent (e.g. full_rect, left_wide). In that case the response includes a
# `note` flagging the situation so the agent can either re-anchor or set
# custom_minimum_size instead.
#
# Args:
#   node_path:  String (required) — target Control in the edited scene.
#   width:      number — new size.x. Omitted leaves current width.
#   height:    number — new size.y. Omitted leaves current height.
#   min_width:  number — new custom_minimum_size.x. Omitted leaves current.
#   min_height: number — new custom_minimum_size.y. Omitted leaves current.
#
# Response payload:
#   node_path, size ("w,h"), custom_minimum_size ("w,h"),
#   previous_size, previous_custom_minimum_size,
#   note (optional, present when size set on a stretched Control)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "set_control_size"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	if node_path.is_empty():
		return ToolUtils.error("node_path is required")
	var node: Node = ToolUtils.find_node_by_path(node_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found" % node_path)
	if not (node is Control):
		return ToolUtils.error_with_solutions(
			"Node '%s' (%s) is not a Control" % [node_path, node.get_class()],
			[
				"set_control_size only applies to Control nodes",
				"For 3D/2D transform updates use set_node_transform",
			]
		)
	var ctrl: Control = node

	if not (args.has("width") or args.has("height") or args.has("min_width") or args.has("min_height")):
		return ToolUtils.error(
			"At least one of width / height / min_width / min_height is required"
		)

	var prev_size := ctrl.size
	var prev_min := ctrl.custom_minimum_size

	var new_size := prev_size
	if args.has("width"):
		new_size.x = ToolUtils.parse_float_arg(args, "width", prev_size.x)
	if args.has("height"):
		new_size.y = ToolUtils.parse_float_arg(args, "height", prev_size.y)
	if new_size != prev_size:
		ctrl.size = new_size

	var new_min := prev_min
	if args.has("min_width"):
		new_min.x = ToolUtils.parse_float_arg(args, "min_width", prev_min.x)
	if args.has("min_height"):
		new_min.y = ToolUtils.parse_float_arg(args, "min_height", prev_min.y)
	if new_min != prev_min:
		ctrl.custom_minimum_size = new_min

	var extras := {
		"node_path": node_path,
		"size": _vec2_str(ctrl.size),
		"custom_minimum_size": _vec2_str(ctrl.custom_minimum_size),
		"previous_size": _vec2_str(prev_size),
		"previous_custom_minimum_size": _vec2_str(prev_min),
	}

	# Warn when size was set on a stretched Control — size will get clobbered
	# on the next layout pass.
	if (args.has("width") or args.has("height")) and _is_stretched(ctrl):
		extras["note"] = (
			"size has no persistent effect on this Control — its anchors stretch it to fit its parent. "
			+ "Re-anchor via set_control_anchors (preset='top_left'/'center'/etc.) or set custom_minimum_size instead."
		)

	return ToolUtils.success(
		"Updated size on '%s'" % node_path,
		extras
	)


# A Control is "stretched" if any anchor pair spans (left != right or top != bottom).
# Stretched Controls take their size from the parent rect, not from .size.
func _is_stretched(ctrl: Control) -> bool:
	return ctrl.anchor_left != ctrl.anchor_right or ctrl.anchor_top != ctrl.anchor_bottom


func _vec2_str(v: Vector2) -> String:
	return "%s,%s" % [v.x, v.y]
