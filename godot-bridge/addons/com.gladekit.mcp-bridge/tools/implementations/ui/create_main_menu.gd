extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates a complete TITLE-SCREEN scene in ONE call — the entry point that turns
# a single playable level into an actual game with a front door. It writes a NEW
# .tscn (it does NOT touch the currently open scene): a Control root with a dim
# background, a centered title, a Play button that loads the gameplay scene, and
# an optional Quit button. A vetted script wires the buttons. Optionally sets the
# new menu as the project's main scene so "run the project" opens it first.
#
# Why a template tool: a menu is trivial conceptually but easy to get subtly
# wrong — buttons that don't appear (no CanvasLayer/anchors), a Play button wired
# to a NodePath that breaks when the tree changes, change_scene_to_file pointed at
# a path that doesn't exist. The vetted script connects buttons by node lookup in
# _ready (no fragile editor connections) and guards an unset target.
#
# Pairs with create_pause_menu (the in-game Esc overlay, whose "quit to menu"
# routes back to the scene this tool creates) and create_game_manager (the
# gameplay scene's score/lives hub).
#
# Args:
#   path:             res:// path for the new menu scene. Default
#                     "res://scenes/main_menu.tscn". Auto-appends .tscn.
#   directory:        res:// folder for the generated script. Default "res://scripts".
#   title:            title text shown on the screen. Default "My Game".
#   play_target:      res:// path of the scene Play loads (your gameplay scene).
#                     Empty is allowed (the button warns at runtime until set).
#   include_quit:     add a Quit button (quits the app). Default true.
#   set_as_main_scene: point the project's run/main_scene at this menu. Default false.
#   open:             open the new scene in the editor after creating it. Default true.
#   overwrite:        overwrite the scene + script if they exist. Default false.
#
# Response payload:
#   path (scene), created_script, play_target, is_main_scene, opened

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")
const DemoAssetsGuard = preload("res://addons/com.gladekit.mcp-bridge/services/demo_assets_guard.gd")

const _MAIN_SCENE_SETTING := "application/run/main_scene"

# ── Vetted script: MainMenu (Play → change scene, Quit → exit) ──────────────
const MENU_SRC := """extends Control

# Title-screen controller. Play loads the gameplay scene; Quit exits. Buttons are
# wired by node lookup in _ready so there's no reliance on editor connections that
# break when the tree is edited. play_target is exported so it shows in the
# inspector and can be repointed without touching code.

# res:// path of the gameplay scene Play loads.
@export_file(\"*.tscn\") var play_target: String = \"\"

@onready var _play_button: Button = get_node_or_null(\"CenterContainer/VBox/PlayButton\")
@onready var _quit_button: Button = get_node_or_null(\"CenterContainer/VBox/QuitButton\")


func _ready() -> void:
	if _play_button != null:
		_play_button.pressed.connect(_on_play_pressed)
		_play_button.grab_focus()
	if _quit_button != null:
		_quit_button.pressed.connect(_on_quit_pressed)


func _on_play_pressed() -> void:
	if play_target.is_empty():
		push_warning(\"MainMenu: play_target is not set — nothing to load. Set it in the inspector or re-run create_main_menu with play_target.\")
		return
	get_tree().change_scene_to_file(play_target)


func _on_quit_pressed() -> void:
	get_tree().quit()
"""


func _init() -> void:
	tool_name = "create_main_menu"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var path: String = ToolUtils.parse_path_arg(args, "path")
	if path.is_empty():
		path = "res://scenes/main_menu.tscn"
	if path.get_extension().is_empty():
		path += ".tscn"
	var ext := path.get_extension().to_lower()
	if ext != "tscn" and ext != "scn":
		return ToolUtils.error("path must end in .tscn or .scn (got .%s)" % ext)

	var guard_err := DemoAssetsGuard.check_write(path)
	if not guard_err.is_empty():
		return ToolUtils.error(guard_err)

	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", false)
	if FileAccess.file_exists(path) and not overwrite:
		return ToolUtils.error_with_solutions(
			"Scene already exists at '%s'" % path,
			["Pass overwrite=true to regenerate it", "Or pick a different 'path'"]
		)

	var directory: String = ToolUtils.parse_string_arg(args, "directory", "res://scripts")
	if directory.is_empty():
		directory = "res://scripts"
	directory = directory.rstrip("/")
	if not directory.begins_with("res://"):
		directory = "res://" + directory.lstrip("/")

	var title: String = ToolUtils.parse_string_arg(args, "title", "My Game")
	if title.is_empty():
		title = "My Game"
	var play_target: String = ToolUtils.parse_string_arg(args, "play_target", "")
	var include_quit: bool = ToolUtils.parse_bool_arg(args, "include_quit", true)
	var set_as_main: bool = ToolUtils.parse_bool_arg(args, "set_as_main_scene", false)
	var should_open: bool = ToolUtils.parse_bool_arg(args, "open", true)

	# ── Write the vetted script ──
	var script_path := directory + "/main_menu.gd"
	if FileAccess.file_exists(script_path) and not overwrite:
		return ToolUtils.error_with_solutions(
			"Refused to overwrite existing script '%s'" % script_path,
			["Pass overwrite=true to regenerate the vetted script", "Or pass a different 'directory'"]
		)
	var make_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	if make_err != OK and make_err != ERR_ALREADY_EXISTS:
		return ToolUtils.error("Failed to create directory '%s' (error %d)" % [directory, make_err])
	var werr := _write_file(script_path, MENU_SRC)
	if werr != "":
		return ToolUtils.error(werr)
	SessionTracker.mark_created(script_path)
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(script_path)

	# ── Build the menu node tree ──
	var root := Control.new()
	root.name = "MainMenu"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bg := ColorRect.new()
	bg.name = "Background"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.07, 0.08, 0.12, 1.0)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)
	bg.owner = root

	var center := CenterContainer.new()
	center.name = "CenterContainer"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	center.owner = root

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.add_theme_constant_override("separation", 18)
	center.add_child(vbox)
	vbox.owner = root

	var title_label := Label.new()
	title_label.name = "TitleLabel"
	title_label.text = title
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", 56)
	vbox.add_child(title_label)
	title_label.owner = root

	var play_button := Button.new()
	play_button.name = "PlayButton"
	play_button.text = "Play"
	play_button.custom_minimum_size = Vector2(220, 48)
	vbox.add_child(play_button)
	play_button.owner = root

	if include_quit:
		var quit_button := Button.new()
		quit_button.name = "QuitButton"
		quit_button.text = "Quit"
		quit_button.custom_minimum_size = Vector2(220, 48)
		vbox.add_child(quit_button)
		quit_button.owner = root

	var menu_script = load(script_path)
	if not (menu_script is Script):
		root.free()
		return ToolUtils.error("Wrote menu script but could not load it from '%s'" % script_path)
	root.set_script(menu_script)
	root.set("play_target", play_target)

	# ── Save the new scene ──
	var dir_path := path.get_base_dir()
	if not dir_path.is_empty():
		var derr := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
		if derr != OK and derr != ERR_ALREADY_EXISTS:
			root.free()
			return ToolUtils.error("Failed to create directory '%s' (err %d)" % [dir_path, derr])

	var packed := PackedScene.new()
	var pack_err := packed.pack(root)
	root.free()
	if pack_err != OK:
		return ToolUtils.error("PackedScene.pack failed for the menu (err %d)" % pack_err)
	var save_err := ResourceSaver.save(packed, path)
	if save_err != OK:
		return ToolUtils.error("ResourceSaver.save failed for '%s' (err %d)" % [path, save_err])
	SessionTracker.mark_created(path)
	if fs != null:
		fs.update_file(path)

	# ── Optionally make it the project's main scene ──
	var is_main := false
	if set_as_main:
		ProjectSettings.set_setting(_MAIN_SCENE_SETTING, path)
		var psave := ProjectSettings.save()
		is_main = psave == OK

	if should_open:
		EditorInterface.open_scene_from_path(path)

	var target_note := (
		"Play loads '%s'." % play_target if not play_target.is_empty()
		else "Play has NO target yet — re-run with play_target (or set it in the inspector) so Play loads your gameplay scene."
	)
	var main_note := (" Set as the project's main scene." if is_main else "")
	return ToolUtils.success(
		"Created a title-screen scene at '%s' — the front door that makes this a complete game. This tool is "
		% path
		+ "ATOMIC: it wrote a VETTED main-menu script VERBATIM and built the Control tree (background + centered "
		+ "title + Play/Quit buttons). DO NOT hand-write menu code — the template already wires the buttons safely "
		+ "(node lookup in _ready, not fragile editor connections) and guards an unset target. "
		+ target_note
		+ main_note
		+ " This is a SEPARATE scene from your gameplay scene — switch back with open_scene to keep building the level.",
		{
			"path": path,
			"created_script": script_path,
			"play_target": play_target,
			"include_quit": include_quit,
			"is_main_scene": is_main,
			"opened": should_open,
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
