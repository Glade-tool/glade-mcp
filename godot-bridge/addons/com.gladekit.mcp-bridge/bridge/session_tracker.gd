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

# Per-CALL buffer of scripts freshly written during the tool currently
# executing. begin_call() resets it before each tool runs; take_recent_writes()
# drains it after, so the dispatcher can report exactly which scripts a single
# tool call created — even template/scaffolder tools that embed the script body
# internally (their path never appears in the caller's args). Distinct from
# _created_paths, which accumulates for the whole session to guard user code.
static var _recent_writes: Array = []


static func mark_created(script_path: String) -> void:
	if script_path.is_empty():
		return
	var normalized := _normalize(script_path)
	_created_paths[normalized] = true
	_recent_writes.append(normalized)


static func was_created_this_session(script_path: String) -> bool:
	return _created_paths.has(_normalize(script_path))


# Reset the per-call write buffer. Called by the dispatcher immediately before
# a tool's execute() so the buffer reflects only that one call.
static func begin_call() -> void:
	_recent_writes.clear()


# Return and clear the scripts written since the last begin_call(). Order is
# write-order; duplicates (a tool that wrote the same path twice) are collapsed.
static func take_recent_writes() -> Array:
	var seen: Dictionary = {}
	var out: Array = []
	for p in _recent_writes:
		if not seen.has(p):
			seen[p] = true
			out.append(p)
	_recent_writes.clear()
	return out


static func clear() -> void:
	_created_paths.clear()
	_recent_writes.clear()


static func _normalize(path: String) -> String:
	var p := path.strip_edges()
	if p.begins_with("res://") or p.begins_with("user://"):
		return p
	if p.begins_with("/"):
		p = p.substr(1)
	return "res://" + p
