extends RefCounted

# Tracks scripts the bridge created during the current Godot session.
#
# Purpose: protects user code from AI clients that misread a "scaffold a new
# system" prompt as "extend an existing one" and then overwrite real user
# code with modify_script. modify_script consults this tracker; if the
# target script is NOT in the set, the modification is refused unless the
# caller passes confirm_existing_file_modification = true (the explicit
# user-intent gate).
#
# Mirrors GladeAgenticAI.Services.SessionTracker from the Unity bridge.
#
# State is process-local: when the editor restarts (or the addon hot-reloads
# enough to free this class), the tracker resets and every existing file
# becomes "pre-existing" again. That's the correct conservative default.

static var _created_paths: Dictionary = {}


static func mark_created(script_path: String) -> void:
	if script_path.is_empty():
		return
	_created_paths[_normalize(script_path)] = true


static func was_created_this_session(script_path: String) -> bool:
	return _created_paths.has(_normalize(script_path))


static func clear() -> void:
	_created_paths.clear()


static func _normalize(path: String) -> String:
	var p := path.strip_edges()
	if p.begins_with("res://") or p.begins_with("user://"):
		return p
	if p.begins_with("/"):
		p = p.substr(1)
	return "res://" + p
