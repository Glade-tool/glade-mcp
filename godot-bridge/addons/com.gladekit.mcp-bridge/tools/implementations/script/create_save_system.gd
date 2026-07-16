extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Adds a full save/load system in ONE call by writing a VETTED GDScript verbatim
# and registering it as an AUTOLOAD singleton (default name "SaveManager"). It is
# the missing piece that turns a session-only prototype into a game that REMEMBERS
# — player progress, unlocked levels, high scores, and settings survive a quit.
#
# Why an autoload (and not a per-scene node): save data is global to the whole
# game, not to one level. An autoload lives at the SceneTree root and is reachable
# from every scene by name (no node reference, no group lookup), which is exactly
# the access pattern persistence needs — a coin pickup in level 3 and the title
# screen's "Continue" button both talk to the same SaveManager. It is also the
# idiomatic Godot pattern for a global service.
#
# Why a template tool: hand-rolled save systems reliably ship data-loss bugs —
# writing to res:// (read-only in an exported game), forgetting to create the
# directory, no error handling on a corrupt/half-written file, or saving to a
# path that differs between editor and export. The vetted script avoids all of
# these: it persists JSON to user:// (the only writable, per-user, cross-platform
# location), tolerates a missing/corrupt file by starting empty, supports multiple
# save slots, and auto-saves on quit so progress is never silently dropped.
#
# Reach it from anywhere by its autoload name (no node reference / group lookup):
#     SaveManager.set_value("coins", 42)      # remember something
#     var coins = SaveManager.get_value("coins", 0)   # read it back (0 if unset)
#     SaveManager.save()                        # flush to disk now
#     if SaveManager.has_save(): ...            # is there a save to continue from?
#     SaveManager.set_slot(1)                   # switch to a second save slot
# Wire it into gameplay by calling set_value on progress changes (score, level,
# unlocks) and get_value on startup to restore them. Pair with create_main_menu
# (a "Continue" button gated on SaveManager.has_save()) and create_game_manager
# (persist the high score).
#
# Args:
#   directory:      res:// folder for the generated script. Default "res://scripts".
#   singleton_name: autoload (global) name. Must be a valid identifier. Default
#                   "SaveManager".
#   autosave:       auto-save on quit (and app-pause on mobile). Default true.
#   default_slot:   which save slot the game starts on (0-based). Each slot is a
#                   separate file (user://savegame_<slot>.json). Default 0.
#   overwrite:      overwrite the generated script if it already exists. Default
#                   false (reuses the existing script; autosave/default_slot then
#                   apply only with overwrite=true).
#
# Response payload:
#   created_script, singleton (autoload name), autoload (the project.godot value),
#   reused_existing_script, triggers (the one-liners to call from gameplay)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")

# ── Vetted script: SaveManager autoload (JSON persistence to user://) ─────────
# __AUTOSAVE__ and __DEFAULT_SLOT__ are substituted with the parsed args before
# the file is written (an autoload is engine-instantiated, so its exported
# defaults can't be set from here the way a scene node's can).
const SAVE_SRC := """extends Node

# Global save/load service, registered as an autoload so every scene can reach it
# by name. Persists a flat key/value store as JSON under user:// — the only
# writable, per-user, cross-platform location (res:// is read-only in an exported
# game). Reach it globally by its autoload name:
#     SaveManager.set_value(\"coins\", 42)
#     var coins = SaveManager.get_value(\"coins\", 0)
#     SaveManager.save()
#
# Store JSON-native values (int, float, bool, String, Array, Dictionary). Engine
# types like Vector2/Color are NOT JSON-native — persist them as components
# (e.g. set_value(\"pos_x\", pos.x)) or an array [x, y].

signal saved     # emitted after a successful save()
signal loaded    # emitted after load_data() reads an existing file

## Auto-save on quit (and on app-pause on mobile) so progress is never dropped.
@export var autosave: bool = __AUTOSAVE__
## Which save slot is active. Each slot is a separate file. Use set_slot() to switch.
@export var slot: int = __DEFAULT_SLOT__

var _data: Dictionary = {}


func _ready() -> void:
	# An autoload keeps running even when the tree is paused (e.g. a pause menu),
	# so a save triggered from a paused state still works.
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_data()


func _notification(what: int) -> void:
	if not autosave:
		return
	# Save on window close (desktop) and on app going to background (mobile),
	# the two moments a session can end without an explicit save() call.
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		save()


# ── Key/value access ─────────────────────────────────────────────────────────

func set_value(key: String, value) -> void:
	_data[key] = value


func get_value(key: String, default_value = null):
	return _data.get(key, default_value)


func has_key(key: String) -> bool:
	return _data.has(key)


func erase_key(key: String) -> void:
	_data.erase(key)


func clear() -> void:
	_data.clear()


# ── Persistence ──────────────────────────────────────────────────────────────

func _path() -> String:
	return \"user://savegame_%d.json\" % slot


# Write the current data to disk as JSON. Returns true on success.
func save() -> bool:
	var f := FileAccess.open(_path(), FileAccess.WRITE)
	if f == null:
		push_error(\"[SaveManager] Could not open '%s' for writing (error %d)\" % [_path(), FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify(_data, \"\\t\"))
	f.close()
	saved.emit()
	return true


# Load data from disk into memory. Missing file → start empty (not an error).
# Corrupt file → warn and start empty rather than crash. Returns true if an
# existing, valid save was read.
func load_data() -> bool:
	if not has_save():
		_data = {}
		return false
	var f := FileAccess.open(_path(), FileAccess.READ)
	if f == null:
		push_error(\"[SaveManager] Could not open '%s' for reading (error %d)\" % [_path(), FileAccess.get_open_error()])
		return false
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		_data = parsed
		loaded.emit()
		return true
	push_warning(\"[SaveManager] Save file '%s' is corrupt or not a JSON object; starting empty.\" % _path())
	_data = {}
	return false


func has_save() -> bool:
	return FileAccess.file_exists(_path())


# Delete the current slot's save file and clear in-memory data. Returns true if a
# file was removed.
func delete_save() -> bool:
	_data.clear()
	if not has_save():
		return false
	var abs := ProjectSettings.globalize_path(_path())
	var err := DirAccess.remove_absolute(abs)
	return err == OK


# Switch to a different save slot and load its data (if any). Useful for a
# multiple-save-file UI.
func set_slot(new_slot: int) -> void:
	slot = new_slot
	load_data()
"""


func _init() -> void:
	tool_name = "create_save_system"
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

	var singleton_name: String = ToolUtils.parse_string_arg(args, "singleton_name", "SaveManager")
	if singleton_name.is_empty():
		singleton_name = "SaveManager"
	if not _is_valid_identifier(singleton_name):
		return ToolUtils.error_with_solutions(
			"singleton_name '%s' is not a valid identifier" % singleton_name,
			[
				"Use letters, digits, and underscores only, not starting with a digit (e.g. 'SaveManager')",
			]
		)

	var autosave: bool = ToolUtils.parse_bool_arg(args, "autosave", true)
	var default_slot: int = ToolUtils.parse_int_arg(args, "default_slot", 0)
	if default_slot < 0:
		default_slot = 0
	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", false)

	var script_path := directory + "/save_manager.gd"
	var script_exists := FileAccess.file_exists(script_path)

	# Reuse the vetted script if it already exists (a project may already have a
	# save system), only (re)writing when absent or overwrite=true so manual edits
	# survive. autosave/default_slot are baked into the FILE, so they only take
	# effect on a (re)write — surface that when reusing.
	var reused_existing := script_exists and not overwrite
	if not script_exists or overwrite:
		var make_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if make_err != OK and make_err != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (error %d)" % [directory, make_err])
		var src := _render_source(autosave, default_slot)
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
		"set_value": "%s.set_value(\"coins\", 42)" % singleton_name,
		"get_value": "var coins = %s.get_value(\"coins\", 0)" % singleton_name,
		"save": "%s.save()" % singleton_name,
		"has_save": "if %s.has_save(): pass  # gate a Continue button on this" % singleton_name,
		"set_slot": "%s.set_slot(1)" % singleton_name,
	}

	var reuse_note := ""
	if reused_existing:
		reuse_note = (
			" The script already existed, so it was REUSED and the autosave/default_slot args were "
			+ "NOT applied — pass overwrite=true to regenerate it with new values."
		)

	return ToolUtils.success(
		"Registered '%s' as an autoload save/load system. This tool is ATOMIC: it wrote a VETTED, "
		% singleton_name
		+ "known-good GDScript VERBATIM and registered it as a project autoload (a save system is global, so "
		+ "it must be a singleton reachable from every scene). DO NOT hand-write save/load code — the template "
		+ "already persists JSON to user:// (the only writable, per-user, cross-platform location), tolerates a "
		+ "missing or corrupt file, supports multiple slots, and auto-saves on quit. Reach it globally by name: "
		+ "%s.set_value(\"coins\", 42) to remember a value, %s.get_value(\"coins\", 0) to read it back (with a "
		% [singleton_name, singleton_name]
		+ "default when unset), %s.save() to flush to disk, and %s.has_save() to gate a Continue button. The "
		% [singleton_name, singleton_name]
		+ "autoload activates on the next play; you don't need to add anything to the scene." + reuse_note,
		{
			"created_script": script_path,
			"singleton": singleton_name,
			"autoload": autoload_value,
			"reused_existing_script": reused_existing,
			"triggers": triggers,
		}
	)


# ── Helpers ─────────────────────────────────────────────────────────────────

func _render_source(autosave: bool, default_slot: int) -> String:
	var out := SAVE_SRC.replace("__AUTOSAVE__", "true" if autosave else "false")
	out = out.replace("__DEFAULT_SLOT__", str(default_slot))
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
