extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Drops a working PAUSE OVERLAY into the CURRENTLY OPEN scene in ONE call. Esc
# (the built-in "ui_cancel" action) toggles get_tree().paused; while paused a
# centered panel with Resume and "Quit to menu" buttons appears. It writes a
# vetted script and builds the node tree — a CanvasLayer (screen-space, above the
# game) whose process_mode is ALWAYS so it keeps running while the rest of the
# tree is frozen (the bug everyone hits: a pause menu that pauses itself and can
# never un-pause).
#
# Works in both 2D and 3D scenes (a CanvasLayer overlay is dimension-agnostic).
# One pause menu per scene — the tool refuses to add a second (two overlays would
# fight over get_tree().paused). Uses the engine's built-in ui_cancel action, so
# no input-map setup is needed.
#
# Pairs with create_main_menu: set this tool's menu_target to the menu scene so
# "Quit to menu" returns there (empty menu_target makes that button quit the app).
#
# Args:
#   directory:    res:// folder for the generated script. Default "res://scripts".
#   menu_target:  res:// path of the menu scene "Quit to menu" loads. Empty = the
#                 button quits the application instead. Default "".
#   overwrite:    overwrite the generated script if it exists. Default false.
#
# Response payload:
#   created_script, pause_menu (node path), group ("pause_menu"), menu_target

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")

const _GROUP := "pause_menu"

# ── Vetted script: PauseMenu (Esc toggles pause; Resume / Quit-to-menu) ──────
const MENU_SRC := """extends CanvasLayer

# Pause overlay. Esc (ui_cancel) toggles get_tree().paused; the panel is shown
# only while paused. This layer's process_mode is ALWAYS so it keeps running
# while the rest of the tree is frozen — otherwise it could pause but never
# un-pause itself. Children inherit ALWAYS, so the buttons stay clickable.

# res:// path of the menu scene \"Quit to menu\" loads. Empty quits the app.
@export_file(\"*.tscn\") var menu_target: String = \"\"

@onready var _panel: Control = get_node_or_null(\"Panel\")
@onready var _resume_button: Button = get_node_or_null(\"Panel/CenterContainer/VBox/ResumeButton\")
@onready var _quit_button: Button = get_node_or_null(\"Panel/CenterContainer/VBox/QuitButton\")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(\"pause_menu\")
	if _panel != null:
		_panel.visible = false
	if _resume_button != null:
		_resume_button.pressed.connect(_on_resume_pressed)
	if _quit_button != null:
		_quit_button.pressed.connect(_on_quit_pressed)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(\"ui_cancel\"):
		_set_paused(not get_tree().paused)
		get_viewport().set_input_as_handled()


func _set_paused(paused: bool) -> void:
	get_tree().paused = paused
	if _panel != null:
		_panel.visible = paused
	if paused and _resume_button != null:
		_resume_button.grab_focus()


func _on_resume_pressed() -> void:
	_set_paused(false)


func _on_quit_pressed() -> void:
	# Clear pause before leaving — the next scene must not inherit a frozen tree.
	get_tree().paused = false
	if menu_target.is_empty():
		get_tree().quit()
	else:
		get_tree().change_scene_to_file(menu_target)
"""


func _init() -> void:
	tool_name = "create_pause_menu"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene with an existing res:// path", "Call create_scene to scaffold a scene first"]
		)

	# One overlay per scene — a second would fight over get_tree().paused.
	var existing := _find_in_group(root, _GROUP)
	if existing != null:
		return ToolUtils.error_with_solutions(
			"A pause menu already exists in this scene (node '%s')" % existing.name,
			[
				"Reuse the existing pause menu — Esc already toggles it",
				"Delete the existing one first if you want a fresh overlay",
			]
		)

	var directory: String = ToolUtils.parse_string_arg(args, "directory", "res://scripts")
	if directory.is_empty():
		directory = "res://scripts"
	directory = directory.rstrip("/")
	if not directory.begins_with("res://"):
		directory = "res://" + directory.lstrip("/")

	var menu_target: String = ToolUtils.parse_string_arg(args, "menu_target", "")
	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", false)

	# The pause-menu script is a shared, vetted template — not a user asset. When
	# it already exists, REUSE it rather than aborting: the per-scene group guard
	# above already prevents a duplicate overlay, so a fresh scene with no pause
	# menu should still get one wired to the existing script. Only (re)write when
	# absent or overwrite=true, so a user's manual edits survive. Mirrors
	# create_collectible / create_hazard.
	var script_path := directory + "/pause_menu.gd"
	var script_exists := FileAccess.file_exists(script_path)
	if not script_exists or overwrite:
		var make_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if make_err != OK and make_err != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (error %d)" % [directory, make_err])
		var werr := _write_file(script_path, MENU_SRC)
		if werr != "":
			return ToolUtils.error(werr)
		if not script_exists:
			SessionTracker.mark_created(script_path)
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(script_path)

	# ── Build the overlay node tree ──
	var layer := CanvasLayer.new()
	layer.name = "PauseMenu"
	# Keep running while the tree is paused (cascades to children via INHERIT).
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	layer.layer = 10  # above gameplay HUD layers
	root.add_child(layer)
	layer.owner = root

	var panel := Control.new()
	panel.name = "Panel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.visible = false
	layer.add_child(panel)
	panel.owner = root

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.6)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(dim)
	dim.owner = root

	var center := CenterContainer.new()
	center.name = "CenterContainer"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(center)
	center.owner = root

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.add_theme_constant_override("separation", 16)
	center.add_child(vbox)
	vbox.owner = root

	var label := Label.new()
	label.name = "PausedLabel"
	label.text = "Paused"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 48)
	vbox.add_child(label)
	label.owner = root

	var resume_button := Button.new()
	resume_button.name = "ResumeButton"
	resume_button.text = "Resume"
	resume_button.custom_minimum_size = Vector2(220, 48)
	vbox.add_child(resume_button)
	resume_button.owner = root

	var quit_button := Button.new()
	quit_button.name = "QuitButton"
	quit_button.text = "Quit to menu" if not menu_target.is_empty() else "Quit"
	quit_button.custom_minimum_size = Vector2(220, 48)
	vbox.add_child(quit_button)
	quit_button.owner = root

	var menu_script = load(script_path)
	if not (menu_script is Script):
		layer.free()
		return ToolUtils.error("Wrote pause-menu script but could not load it from '%s'" % script_path)
	layer.set_script(menu_script)
	layer.set("menu_target", menu_target)
	if not layer.is_in_group(_GROUP):
		layer.add_to_group(_GROUP, true)

	var quit_note := (
		"\"Quit to menu\" returns to '%s'." % menu_target if not menu_target.is_empty()
		else "\"Quit\" exits the app — pass menu_target (a menu scene) to make it return to a menu instead."
	)
	return ToolUtils.success(
		"Added a pause overlay to this scene — Esc toggles it. This tool is ATOMIC: it wrote a VETTED pause script "
		+ "VERBATIM and built the overlay (a CanvasLayer with process_mode ALWAYS so it can un-pause itself — the "
		+ "trap that breaks hand-written pause menus — over a hidden Resume / Quit panel). DO NOT hand-write pause "
		+ "code. It uses the built-in ui_cancel (Esc) action, so no input setup is needed. "
		+ quit_note
		+ " Your remaining step is to call save_scene.",
		{
			"created_script": script_path,
			"pause_menu": ToolUtils.node_relative_path(layer),
			"group": _GROUP,
			"menu_target": menu_target,
		}
	)


# ── Helpers ─────────────────────────────────────────────────────────────────

func _write_file(file_path: String, content: String) -> String:
	var f := FileAccess.open(file_path, FileAccess.WRITE)
	if f == null:
		return "Could not open '%s' for writing (FileAccess error %d)" % [file_path, FileAccess.get_open_error()]
	f.store_string(content)
	f.close()
	return ""


# Group lookup that works before the edited scene is inside the live SceneTree
# (the editor's edited scene isn't part of get_tree()). Walks the node subtree.
func _find_in_group(node: Node, group: String) -> Node:
	if node.is_in_group(group):
		return node
	for child in node.get_children():
		var found := _find_in_group(child, group)
		if found != null:
			return found
	return null
