extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Read-only walk of the Control tree in the edited scene. Like get_scene_tree
# but filtered to Control nodes (and the CanvasLayer / SubViewport hosts that
# parent them) plus carrying UI-relevant fields the generic scene-tree dump
# doesn't bother with: size, position, anchor preset, text, visibility.
#
# Args:
#   root_path:    String — scene-relative root for the walk. Default scene root.
#   include_text: bool   — include current text on text-bearing Controls.
#                          Default true. Set false to keep payload tight on
#                          UI-heavy scenes.
#   max_elements: int    — cap on returned elements. Default 200, clamp 1..1000.
#
# Response payload:
#   elements:    [{path, type, size, position, anchor_preset, text?, visible}]
#                  — anchor_preset is the best-match preset name (or "custom"
#                    if the anchors don't match any built-in preset)
#                  — text omitted when include_text=false or the Control has none
#   count:       int
#   truncated:   bool

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const DEFAULT_MAX := 200
const HARD_CAP := 1000

# Reverse mapping: anchor four-tuple → preset name. Used to label a Control's
# current anchors with a recognizable preset (or "custom" when no match).
# Tuples are (anchor_left, anchor_top, anchor_right, anchor_bottom).
const _PRESET_ANCHORS := [
	[Vector4(0, 0, 0, 0),       "top_left"],
	[Vector4(1, 0, 1, 0),       "top_right"],
	[Vector4(0, 1, 0, 1),       "bottom_left"],
	[Vector4(1, 1, 1, 1),       "bottom_right"],
	[Vector4(0, 0.5, 0, 0.5),   "center_left"],
	[Vector4(0.5, 0, 0.5, 0),   "center_top"],
	[Vector4(1, 0.5, 1, 0.5),   "center_right"],
	[Vector4(0.5, 1, 0.5, 1),   "center_bottom"],
	[Vector4(0.5, 0.5, 0.5, 0.5), "center"],
	[Vector4(0, 0, 0, 1),       "left_wide"],
	[Vector4(0, 0, 1, 0),       "top_wide"],
	[Vector4(1, 0, 1, 1),       "right_wide"],
	[Vector4(0, 1, 1, 1),       "bottom_wide"],
	[Vector4(0.5, 0, 0.5, 1),   "vcenter_wide"],
	[Vector4(0, 0.5, 1, 0.5),   "hcenter_wide"],
	[Vector4(0, 0, 1, 1),       "full_rect"],
]

# Same text-property table as set_control_text (kept duplicated to avoid a
# shared util module — three is the tipping point for extraction; we're at two).
const TEXT_PROPERTY := {
	"Button": "text",
	"Label": "text",
	"LineEdit": "text",
	"TextEdit": "text",
	"RichTextLabel": "text",
	"CheckBox": "text",
	"CheckButton": "text",
	"OptionButton": "text",
	"MenuButton": "text",
	"LinkButton": "text",
	"AcceptDialog": "dialog_text",
	"ConfirmationDialog": "dialog_text",
	"FileDialog": "dialog_text",
}


func _init() -> void:
	tool_name = "list_ui_hierarchy"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var root_path: String = ToolUtils.parse_string_arg(args, "root_path")
	var include_text: bool = ToolUtils.parse_bool_arg(args, "include_text", true)
	var max_elements: int = clamp(ToolUtils.parse_int_arg(args, "max_elements", DEFAULT_MAX), 1, HARD_CAP)

	var scene_root: Node = EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return ToolUtils.error("No scene is currently open in the editor")

	var walk_root: Node
	if root_path.is_empty():
		walk_root = scene_root
	else:
		walk_root = ToolUtils.find_node_by_path(root_path)
		if walk_root == null:
			return ToolUtils.error("Root node '%s' not found" % root_path)

	var elements: Array = []
	var truncated := false
	# DFS so the order matches the scene-tree dock visually.
	var stack: Array = [walk_root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		# Children pushed in reverse so we visit them in left-to-right order.
		var children := node.get_children()
		for i in range(children.size() - 1, -1, -1):
			stack.push_back(children[i])

		if not (node is Control):
			continue
		var ctrl: Control = node
		var entry := {
			"path": ToolUtils.node_relative_path(ctrl),
			"type": ctrl.get_class(),
			"size": "%s,%s" % [ctrl.size.x, ctrl.size.y],
			"position": "%s,%s" % [ctrl.position.x, ctrl.position.y],
			"anchor_preset": _detect_preset(ctrl),
			"visible": ctrl.visible,
		}
		if include_text:
			var text_prop := _text_property_for(ctrl.get_class())
			if not text_prop.is_empty():
				entry["text"] = str(ctrl.get(text_prop))
		elements.append(entry)
		if elements.size() >= max_elements:
			truncated = true
			break

	return ToolUtils.success(
		"Found %d Control(s)" % elements.size(),
		{
			"elements": elements,
			"count": elements.size(),
			"truncated": truncated,
		}
	)


func _detect_preset(ctrl: Control) -> String:
	var anchors := Vector4(ctrl.anchor_left, ctrl.anchor_top, ctrl.anchor_right, ctrl.anchor_bottom)
	for pair in _PRESET_ANCHORS:
		if pair[0] == anchors:
			return pair[1]
	return "custom"


func _text_property_for(type_name: String) -> String:
	var current := type_name
	for _i in 12:
		if current.is_empty():
			return ""
		if TEXT_PROPERTY.has(current):
			return TEXT_PROPERTY[current]
		current = ClassDB.get_parent_class(current)
	return ""
