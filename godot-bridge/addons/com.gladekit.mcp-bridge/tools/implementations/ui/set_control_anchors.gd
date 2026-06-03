extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Apply one of Godot's built-in anchor presets to a Control. Mirrors the
# editor's anchor menu (top-right of the Layout submenu in the 2D editor).
#
# Two modes via keep_offsets:
#   false (default): set_anchors_and_offsets_preset — recomputes offsets so the
#                    Control's visual rect snaps to the preset. Usually what
#                    the agent wants ("make this fill the screen").
#   true           : set_anchors_preset — preserves current offsets. Useful for
#                    re-anchoring an already-positioned Control without moving it.
#
# Args:
#   node_path:    String (required) — target Control in the edited scene.
#   preset:       String (required) — see PRESETS table below.
#   keep_offsets: bool — preserve offsets when changing anchors. Default false.
#
# Response payload:
#   node_path, preset, preset_id, mode ("recompute" | "preserve")

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

# Authoritative preset name → Godot enum mapping. Kept in this file (rather
# than a shared util) so the table is the public API for both this tool and
# create_control's anchor_preset arg.
const PRESETS := {
	"top_left":      Control.PRESET_TOP_LEFT,
	"top_right":     Control.PRESET_TOP_RIGHT,
	"bottom_left":   Control.PRESET_BOTTOM_LEFT,
	"bottom_right":  Control.PRESET_BOTTOM_RIGHT,
	"center_left":   Control.PRESET_CENTER_LEFT,
	"center_top":    Control.PRESET_CENTER_TOP,
	"center_right":  Control.PRESET_CENTER_RIGHT,
	"center_bottom": Control.PRESET_CENTER_BOTTOM,
	"center":        Control.PRESET_CENTER,
	"left_wide":     Control.PRESET_LEFT_WIDE,
	"top_wide":      Control.PRESET_TOP_WIDE,
	"right_wide":    Control.PRESET_RIGHT_WIDE,
	"bottom_wide":   Control.PRESET_BOTTOM_WIDE,
	"vcenter_wide":  Control.PRESET_VCENTER_WIDE,
	"hcenter_wide":  Control.PRESET_HCENTER_WIDE,
	"full_rect":     Control.PRESET_FULL_RECT,
}


func _init() -> void:
	tool_name = "set_control_anchors"
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
				"set_control_anchors only applies to Control nodes",
				"For 3D/2D transform updates use set_node_transform",
			]
		)
	var ctrl: Control = node

	var preset_name: String = ToolUtils.parse_string_arg(args, "preset").strip_edges().to_lower()
	if preset_name.is_empty():
		return ToolUtils.error_with_solutions(
			"preset is required",
			["Pick one of the documented presets — see possible_solutions"],
			{"valid_presets": PRESETS.keys()}
		)
	if not PRESETS.has(preset_name):
		return ToolUtils.error_with_solutions(
			"Unknown anchor preset '%s'" % preset_name,
			["Pick one of: " + ", ".join(PRESETS.keys())],
			{"valid_presets": PRESETS.keys()}
		)
	var preset_id: int = PRESETS[preset_name]

	var keep_offsets: bool = ToolUtils.parse_bool_arg(args, "keep_offsets", false)
	if keep_offsets:
		ctrl.set_anchors_preset(preset_id, true)
	else:
		ctrl.set_anchors_and_offsets_preset(preset_id)

	return ToolUtils.success(
		"Applied anchor preset '%s' to '%s'" % [preset_name, node_path],
		{
			"node_path": node_path,
			"preset": preset_name,
			"preset_id": preset_id,
			"mode": "preserve" if keep_offsets else "recompute",
		}
	)
