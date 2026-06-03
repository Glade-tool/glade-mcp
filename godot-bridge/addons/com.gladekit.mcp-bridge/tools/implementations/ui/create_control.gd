extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates a UI-tree node (Button, Label, container, dialog, etc.) with
# UI-appropriate defaults. Accepts both Control subclasses AND Window-based
# popup classes (AcceptDialog, ConfirmationDialog, FileDialog, Popup,
# PopupMenu, PopupPanel) — both are the model's mental model for "UI node"
# even though Window is technically a Viewport in Godot's class hierarchy.
#
# Wraps create_node's generic factory with three pieces of UI-specific
# convenience that the agent otherwise has to discover the hard way:
#
#   1. CanvasLayer auto-wrap. A bare Control under a Node3D scene root renders
#      with no parent CanvasItem context — the model frequently ships UI that
#      "doesn't appear" for this reason. When the resolved parent is the scene
#      root AND the root is not Control/CanvasLayer/SubViewport, we auto-create
#      (or reuse) a CanvasLayer named "UI" and parent the Control under that.
#      Window dialogs are NOT auto-wrapped (they're their own popup viewport
#      and don't need a CanvasLayer parent). Opt out with auto_canvas_layer=false.
#
#   2. Optional one-shot anchor preset. Saves a follow-up set_control_anchors
#      round-trip for the common "make this fill the screen / center it" case.
#      Ignored for Window subclasses (anchors are a Control concept).
#
#   3. Optional one-shot text. For text-bearing classes (Button, Label, LineEdit,
#      TextEdit, RichTextLabel, CheckBox, CheckButton, AcceptDialog) the agent
#      almost always wants to set text at creation time — folding it in here
#      saves another set_control_text round-trip.
#
# Args:
#   type:               String (required) — Control subclass (PascalCase). Common
#                                           values: Button, Label, Panel, ColorRect,
#                                           TextureRect, LineEdit, TextEdit,
#                                           RichTextLabel, HBoxContainer,
#                                           VBoxContainer, GridContainer,
#                                           MarginContainer, CenterContainer,
#                                           PanelContainer, ScrollContainer,
#                                           TabContainer, CheckBox, CheckButton.
#   name:               String — node name. Default: <type>.
#   parent_path:        String — scene-relative parent. Default scene root.
#   text:               String — initial text (text-bearing Control types only).
#   anchor_preset:      String — one of the preset names from set_control_anchors.
#                                Default: no preset applied (Godot's default top-left).
#   auto_canvas_layer:  bool   — wrap in CanvasLayer "UI" when needed. Default true.
#
# Response payload:
#   node_path:         scene-relative path of the new Control
#   type:              confirmed class
#   parent_path:       resolved parent (may differ from `parent_path` arg if
#                      auto_canvas_layer kicked in)
#   canvas_layer_path: path of the auto-created CanvasLayer, or "" if none.
#   text_applied:      bool — true if `text` was set, false if ignored.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const CANVAS_LAYER_NAME := "UI"

# Built-in Control subclasses that carry a `text` property the agent commonly
# wants set at creation. Used as the gate for the `text` arg.
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
}


func _init() -> void:
	tool_name = "create_control"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var type_name: String = ToolUtils.parse_string_arg(args, "type")
	if type_name.is_empty():
		return ToolUtils.error(
			"type is required (e.g. 'Button', 'Label', 'VBoxContainer', 'ColorRect')"
		)

	if not ClassDB.class_exists(type_name):
		return ToolUtils.error("Unknown Godot class '%s'" % type_name)
	# Accept Control subclasses (Button/Label/containers/...) AND Window-based
	# dialog classes (AcceptDialog/ConfirmationDialog/FileDialog/Popup/...). Window
	# is technically Viewport in the class tree, but the agent and the user both
	# think of these as "UI nodes". Anything else routes to create_node.
	var is_control: bool = ClassDB.is_parent_class(type_name, "Control")
	var is_window: bool = ClassDB.is_parent_class(type_name, "Window")
	if not (is_control or is_window):
		return ToolUtils.error_with_solutions(
			"'%s' is not a UI node (Control or Window subclass)" % type_name,
			[
				"For non-UI scene nodes use create_node",
				"For physics bodies use create_physics_body",
				"For 3D meshes use create_primitive_3d",
			]
		)
	if not ClassDB.can_instantiate(type_name):
		return ToolUtils.error("Class '%s' is abstract and cannot be instantiated" % type_name)

	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error("No scene is currently open in the editor")

	var requested_parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node
	if requested_parent_path.is_empty():
		parent = root
	else:
		parent = ToolUtils.find_node_by_path(requested_parent_path)
		if parent == null:
			return ToolUtils.error("Parent node '%s' not found" % requested_parent_path)

	# CanvasLayer auto-wrap. Only kicks in for Control nodes when (a) the
	# resolved parent is the scene root, (b) the root is NOT already a
	# Control-compatible host, and (c) the caller hasn't opted out. Window
	# dialogs are their own popup viewport — they don't render through a
	# CanvasLayer chain and shouldn't be wrapped.
	var auto_canvas: bool = ToolUtils.parse_bool_arg(args, "auto_canvas_layer", true)
	var canvas_layer_path: String = ""
	if is_control and auto_canvas and parent == root and not _is_control_host(root):
		var ui_layer := _find_or_create_ui_layer(root)
		parent = ui_layer
		canvas_layer_path = ToolUtils.node_relative_path(ui_layer)

	var instance = ClassDB.instantiate(type_name)
	if not (instance is Node):
		# Belt-and-suspenders — caught above.
		return ToolUtils.error("ClassDB.instantiate('%s') did not return a Node" % type_name)
	var node_ui: Node = instance

	var node_name: String = ToolUtils.parse_string_arg(args, "name", type_name)
	node_ui.name = node_name

	parent.add_child(node_ui)
	# Owner = scene root so it persists when the scene is saved.
	node_ui.owner = root

	# Optional anchor preset (Control-only — anchors don't exist on Window).
	var preset_name: String = ToolUtils.parse_string_arg(args, "anchor_preset")
	var preset_applied := false
	if not preset_name.is_empty():
		if not is_control:
			# Don't fail the whole call — agent gets a successful create + a
			# clear note about why the preset was skipped.
			return ToolUtils.success(
				"Created %s '%s' under '%s' (anchor_preset '%s' ignored — anchors are a Control concept, %s is a Window)" % [
					type_name, node_ui.name, ToolUtils.node_relative_path(parent), preset_name, type_name
				],
				_response_payload(node_ui, parent, canvas_layer_path, false, preset_name, false)
			)
		var preset_id: int = _anchor_preset_id(preset_name)
		if preset_id < 0:
			return ToolUtils.success(
				"Created %s '%s' under '%s' (anchor_preset '%s' ignored — unknown)" % [
					type_name, node_ui.name, ToolUtils.node_relative_path(parent), preset_name
				],
				_response_payload(node_ui, parent, canvas_layer_path, false, preset_name, false)
			)
		(node_ui as Control).set_anchors_and_offsets_preset(preset_id)
		preset_applied = true

	# Optional text. Silently no-op for classes without a text property —
	# the `text_applied` flag in the response tells the agent whether it stuck.
	var text_applied := false
	if args.has("text") and args["text"] != null:
		var text_prop: String = _text_property_for(type_name)
		if not text_prop.is_empty():
			node_ui.set(text_prop, ToolUtils.parse_string_arg(args, "text"))
			text_applied = true

	return ToolUtils.success(
		"Created %s '%s' under '%s'" % [
			type_name, node_ui.name, ToolUtils.node_relative_path(parent)
		],
		_response_payload(node_ui, parent, canvas_layer_path, text_applied, preset_name, preset_applied)
	)


func _response_payload(
	node_ui: Node,
	parent: Node,
	canvas_layer_path: String,
	text_applied: bool,
	anchor_preset: String,
	preset_applied: bool,
) -> Dictionary:
	return {
		"node_path": ToolUtils.node_relative_path(node_ui),
		"type": node_ui.get_class(),
		"parent_path": ToolUtils.node_relative_path(parent),
		"canvas_layer_path": canvas_layer_path,
		"text_applied": text_applied,
		"anchor_preset": anchor_preset,
		"anchor_preset_applied": preset_applied and not anchor_preset.is_empty(),
	}


# A node is a "Control host" if Controls added beneath it will render correctly:
# Control (and any subclass), CanvasLayer, SubViewport. Anything else (Node3D,
# plain Node, Node2D without CanvasLayer) needs auto-wrapping.
func _is_control_host(node: Node) -> bool:
	if node is Control:
		return true
	if node is CanvasLayer:
		return true
	if node is SubViewport:
		return true
	return false


# Look for an existing CanvasLayer child of the scene root named "UI". Reuse it
# if found (so repeated create_control calls don't pile up CanvasLayers).
func _find_or_create_ui_layer(root: Node) -> CanvasLayer:
	for child in root.get_children():
		if child is CanvasLayer and String(child.name) == CANVAS_LAYER_NAME:
			return child
	var layer := CanvasLayer.new()
	layer.name = CANVAS_LAYER_NAME
	root.add_child(layer)
	layer.owner = root
	return layer


func _text_property_for(type_name: String) -> String:
	if TEXT_PROPERTY.has(type_name):
		return TEXT_PROPERTY[type_name]
	# Walk up the class chain so subclasses inherit. Caps after a few steps to
	# avoid pathological inheritance walks.
	var current := type_name
	for _i in 8:
		current = ClassDB.get_parent_class(current)
		if current.is_empty():
			return ""
		if TEXT_PROPERTY.has(current):
			return TEXT_PROPERTY[current]
	return ""


# Same preset table as set_control_anchors. Kept duplicated here (cheap) so the
# two tools don't need a shared utility module — the table is the public API.
func _anchor_preset_id(preset_name: String) -> int:
	match preset_name.strip_edges().to_lower():
		"top_left":      return Control.PRESET_TOP_LEFT
		"top_right":     return Control.PRESET_TOP_RIGHT
		"bottom_left":   return Control.PRESET_BOTTOM_LEFT
		"bottom_right":  return Control.PRESET_BOTTOM_RIGHT
		"center_left":   return Control.PRESET_CENTER_LEFT
		"center_top":    return Control.PRESET_CENTER_TOP
		"center_right":  return Control.PRESET_CENTER_RIGHT
		"center_bottom": return Control.PRESET_CENTER_BOTTOM
		"center":        return Control.PRESET_CENTER
		"left_wide":     return Control.PRESET_LEFT_WIDE
		"top_wide":      return Control.PRESET_TOP_WIDE
		"right_wide":    return Control.PRESET_RIGHT_WIDE
		"bottom_wide":   return Control.PRESET_BOTTOM_WIDE
		"vcenter_wide":  return Control.PRESET_VCENTER_WIDE
		"hcenter_wide":  return Control.PRESET_HCENTER_WIDE
		"full_rect":     return Control.PRESET_FULL_RECT
		_:               return -1
