extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Adds a full-screen scene-transition overlay in ONE call by writing a VETTED
# GDScript verbatim and registering it as an AUTOLOAD singleton (default name
# "ScreenTransition"). It is the missing piece that turns hard scene CUTS into
# smooth fades — between menu and game, level and level, and on death/respawn.
#
# Why an autoload (and not a per-scene node): a scene transition must fade out,
# swap the scene with change_scene_to_file, then fade back IN. A node living in
# the old scene is freed by that swap, so its fade-in never runs. An autoload
# lives at the SceneTree root and survives scene changes, which is the only place
# this can work — so this tool registers one instead of attaching a node. It is
# also the idiomatic Godot pattern for transitions.
#
# Why a template tool: hand-rolled transitions get the ordering wrong (swap
# before the screen is fully covered, so the cut still flashes through), forget to
# clear the pause a pause-menu left set, build an overlay that doesn't cover the
# whole viewport or sits beneath the HUD, or leak a half-faded overlay between
# transitions. The vetted script avoids all of these: a top-most CanvasLayer
# (layer 128) with a full-rect ColorRect, fade-out → swap → fade-in in the
# correct order, pause cleared before the new scene runs, and a busy guard so
# overlapping calls can't strand a black screen.
#
# Reach it from anywhere by its autoload name (no node reference / group lookup):
#     ScreenTransition.transition_to("res://scenes/level_2.tscn")
#     await ScreenTransition.fade_out()    # cover the screen, then do your thing
#     ScreenTransition.flash(Color.RED)    # quick damage/pickup blink
# Wire it into the menu/pause tools by replacing their direct
# get_tree().change_scene_to_file(path) calls with ScreenTransition.transition_to(path).
#
# Args:
#   directory:      res:// folder for the generated script. Default "res://scripts".
#   singleton_name: autoload (global) name. Must be a valid identifier. Default
#                   "ScreenTransition".
#   color:          fade color, "#rrggbb[aa]" | "r,g,b[,a]". Default black.
#   duration:       default fade time in seconds (each half of a transition).
#                   Default 0.4.
#   overwrite:      overwrite the generated script if it already exists. Default
#                   false (reuses the existing script; color/duration then apply
#                   only with overwrite=true).
#
# Response payload:
#   created_script, singleton (autoload name), autoload (the project.godot value),
#   triggers (the one-liners to call from gameplay/menus)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")

# ── Vetted script: ScreenTransition autoload (fade overlay) ──────────────────
# __FADE_COLOR__ and __DEFAULT_DURATION__ are substituted with the parsed args
# before the file is written (an autoload is engine-instantiated, so its exported
# defaults can't be set from here the way a scene node's can).
const TRANSITION_SRC := """extends CanvasLayer

# Full-screen scene-transition overlay, registered as an autoload so it SURVIVES
# scene changes (a per-scene node would be freed by change_scene_to_file mid-
# transition, killing the fade-in). Reach it globally by its autoload name:
#     ScreenTransition.transition_to(\"res://scenes/level_2.tscn\")
#     await ScreenTransition.fade_out()
#     ScreenTransition.flash(Color.RED)

signal transition_finished

@export var fade_color: Color = __FADE_COLOR__
@export var default_duration: float = __DEFAULT_DURATION__

var _rect: ColorRect
var _busy: bool = false


func _ready() -> void:
	# Run even while the tree is paused (so a pause menu can transition out), and
	# draw above HUDs and menus.
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 128
	_rect = ColorRect.new()
	_rect.color = fade_color
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.modulate.a = 0.0
	_rect.visible = false
	add_child(_rect)


# Fade to opaque, swap to scene_path, then fade back in. Awaitable.
func transition_to(scene_path: String, duration: float = -1.0) -> void:
	if _busy:
		return
	_busy = true
	await fade_out(duration)
	# A pause menu may have paused the tree; clear it so the new scene runs.
	get_tree().paused = false
	get_tree().change_scene_to_file(scene_path)
	# Let the deferred scene swap take effect before uncovering it.
	await get_tree().process_frame
	await fade_in(duration)
	_busy = false
	transition_finished.emit()


# Cover the screen with fade_color. Awaitable: `await ScreenTransition.fade_out()`.
func fade_out(duration: float = -1.0) -> void:
	var d := default_duration if duration < 0.0 else duration
	_rect.color = fade_color
	_rect.visible = true
	var tw := create_tween()
	tw.tween_property(_rect, \"modulate:a\", 1.0, d)
	await tw.finished


# Uncover the screen. Awaitable.
func fade_in(duration: float = -1.0) -> void:
	var d := default_duration if duration < 0.0 else duration
	_rect.visible = true
	var tw := create_tween()
	tw.tween_property(_rect, \"modulate:a\", 0.0, d)
	await tw.finished
	_rect.visible = false


# Quick screen flash for a hit or pickup. Awaitable but short; restores the base
# fade color afterward so it never interferes with a fade.
func flash(color: Color = Color(1, 1, 1, 1), duration: float = 0.18) -> void:
	var prev := _rect.color
	_rect.color = color
	_rect.visible = true
	_rect.modulate.a = 0.55
	var tw := create_tween()
	tw.tween_property(_rect, \"modulate:a\", 0.0, duration)
	await tw.finished
	_rect.color = prev
	_rect.visible = false
"""


func _init() -> void:
	tool_name = "create_scene_transition"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	# Project-level tool: registers an autoload, so it does NOT require an open
	# scene (unlike the per-scene scaffolders). It does need the editor for the
	# filesystem refresh + ProjectSettings.save, hence requires_edit_mode.

	var directory: String = ToolUtils.parse_string_arg(args, "directory", "res://scripts")
	if directory.is_empty():
		directory = "res://scripts"
	directory = directory.rstrip("/")
	if not directory.begins_with("res://"):
		directory = "res://" + directory.lstrip("/")

	var singleton_name: String = ToolUtils.parse_string_arg(args, "singleton_name", "ScreenTransition")
	if singleton_name.is_empty():
		singleton_name = "ScreenTransition"
	if not _is_valid_identifier(singleton_name):
		return ToolUtils.error_with_solutions(
			"singleton_name '%s' is not a valid identifier" % singleton_name,
			[
				"Use letters, digits, and underscores only, not starting with a digit (e.g. 'ScreenTransition')",
			]
		)

	var color: Color = ToolUtils.parse_color_arg(args.get("color"), Color(0, 0, 0, 1))
	var duration: float = ToolUtils.parse_float_arg(args, "duration", 0.4)
	if duration <= 0.0:
		duration = 0.4
	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", false)

	var script_path := directory + "/screen_transition.gd"
	var script_exists := FileAccess.file_exists(script_path)

	# Reuse the vetted script if it already exists (a project may already have a
	# transition), only (re)writing when absent or overwrite=true so manual edits
	# survive. color/duration are baked into the FILE, so they only take effect on
	# a (re)write — surface that when reusing.
	var reused_existing := script_exists and not overwrite
	if not script_exists or overwrite:
		var make_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if make_err != OK and make_err != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (error %d)" % [directory, make_err])
		var src := _render_source(color, duration)
		var werr := _write_file(script_path, src)
		if werr != "":
			return ToolUtils.error(werr)
		if not script_exists:
			SessionTracker.mark_created(script_path)

	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(script_path)

	# Register the autoload via ProjectSettings. The leading "*" marks the
	# singleton enabled. Refuse to silently repoint an existing autoload of the
	# same name at a different script.
	var setting_key := "autoload/" + singleton_name
	var autoload_value := "*" + script_path
	if ProjectSettings.has_setting(setting_key):
		var existing_value: String = str(ProjectSettings.get_setting(setting_key))
		var existing_path := existing_value.trim_prefix("*")
		if existing_path != script_path:
			return ToolUtils.error_with_solutions(
				"An autoload named '%s' already exists, pointing at '%s'" % [singleton_name, existing_path],
				[
					"Pass a different singleton_name",
					"Remove the existing autoload in Project Settings > Autoload first",
				]
			)
	ProjectSettings.set_setting(setting_key, autoload_value)
	var save_err := ProjectSettings.save()
	if save_err != OK:
		return ToolUtils.error("Wrote the script but failed to register the autoload (ProjectSettings.save error %d)" % save_err)

	var triggers := {
		"transition_to": "%s.transition_to(\"res://scenes/your_scene.tscn\")" % singleton_name,
		"fade_out": "await %s.fade_out()" % singleton_name,
		"fade_in": "await %s.fade_in()" % singleton_name,
		"flash": "%s.flash(Color.RED)" % singleton_name,
	}

	var reuse_note := ""
	if reused_existing:
		reuse_note = (
			" The script already existed, so it was REUSED and the color/duration args were "
			+ "NOT applied — pass overwrite=true to regenerate it with new values."
		)

	return ToolUtils.success(
		"Registered '%s' as an autoload scene-transition overlay. This tool is ATOMIC: it wrote a VETTED, "
		% singleton_name
		+ "known-good GDScript VERBATIM and registered it as a project autoload (it must be a singleton to "
		+ "survive change_scene_to_file — a per-scene node would be freed mid-transition). DO NOT hand-write "
		+ "scene transitions — the template already orders fade-out → swap → fade-in correctly, clears a "
		+ "paused tree, and covers the whole screen above the HUD. Reach it globally by name: "
		+ "%s.transition_to(\"res://scenes/level_2.tscn\") for a fade between scenes (use this in place of a bare "
		% singleton_name
		+ "get_tree().change_scene_to_file in your menu/pause/win logic), await %s.fade_out() to cover the screen, "
		% singleton_name
		+ "or %s.flash(Color.RED) for a hit blink. The autoload activates on the next play; you don't need to add "
		% singleton_name
		+ "anything to the scene." + reuse_note,
		{
			"created_script": script_path,
			"singleton": singleton_name,
			"autoload": autoload_value,
			"reused_existing_script": reused_existing,
			"triggers": triggers,
		}
	)


# ── Helpers ─────────────────────────────────────────────────────────────────

func _render_source(color: Color, duration: float) -> String:
	var color_literal := "Color(%.4f, %.4f, %.4f, %.4f)" % [color.r, color.g, color.b, color.a]
	var out := TRANSITION_SRC.replace("__FADE_COLOR__", color_literal)
	out = out.replace("__DEFAULT_DURATION__", "%.3f" % duration)
	return out


func _is_valid_identifier(name: String) -> bool:
	var re := RegEx.new()
	re.compile("^[A-Za-z_][A-Za-z0-9_]*$")
	return re.search(name) != null


func _write_file(path: String, content: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Could not open '%s' for writing (FileAccess error %d)" % [path, FileAccess.get_open_error()]
	f.store_string(content)
	f.close()
	return ""
