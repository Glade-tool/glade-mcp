extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Unified text setter for text-bearing UI nodes. The model otherwise has
# to remember that Button.text, Label.text, LineEdit.text are spelled the
# same way but AcceptDialog.dialog_text isn't — this tool picks the right
# property by class. Accepts both Control AND Window subclasses (Window
# popup dialogs like AcceptDialog/ConfirmationDialog/FileDialog use
# dialog_text, which lives on Window).
#
# Args:
#   node_path: String (required) — target UI node in the edited scene.
#   text:      String (required) — new text. May be empty string to clear.
#
# Response payload:
#   node_path, property (the actual property that was set), text,
#   previous_text (the value before the call)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

# Class → text-property mapping. Most Control text-bearing classes use `text`;
# AcceptDialog (and ConfirmationDialog, FileDialog) use `dialog_text`. Walked
# up the inheritance chain so subclasses inherit correctly.
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
	tool_name = "set_control_text"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	if node_path.is_empty():
		return ToolUtils.error("node_path is required")
	var node: Node = ToolUtils.find_node_by_path(node_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found" % node_path)
	# `text` is required as a key (may be empty string), so the agent can't
	# accidentally clear a label by omitting the arg.
	if not args.has("text"):
		return ToolUtils.error('text is required (pass "" to clear)')
	var new_text: String = ToolUtils.parse_string_arg(args, "text")

	# Type gate is "has a recognized text property" — not "is Control". Window
	# subclasses (AcceptDialog/ConfirmationDialog/FileDialog) are valid here too
	# even though Window is technically Viewport in the class hierarchy.
	var prop: String = _resolve_text_property(node)
	if prop.is_empty():
		return ToolUtils.error_with_solutions(
			"%s has no recognized text property" % node.get_class(),
			[
				"This class doesn't expose a `text` (or `dialog_text`) property",
				"For text on a ColorRect/Panel/TextureRect: add a child Label via create_control",
				"For resource-typed content (e.g. TextureRect.texture): use set_node_resource",
			]
		)

	var previous_text: String = str(node.get(prop))
	node.set(prop, new_text)

	return ToolUtils.success(
		"Set %s.%s on '%s'" % [node.get_class(), prop, node_path],
		{
			"node_path": node_path,
			"property": prop,
			"text": new_text,
			"previous_text": previous_text,
		}
	)


func _resolve_text_property(node: Node) -> String:
	var current := node.get_class()
	for _i in 12:
		if current.is_empty():
			return ""
		if TEXT_PROPERTY.has(current):
			return TEXT_PROPERTY[current]
		current = ClassDB.get_parent_class(current)
	return ""
