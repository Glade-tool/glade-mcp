extends RefCounted

# Single source of truth for "is the editor playing the scene or editing it?"
#
# All tools that mutate the scene MUST check this (the bridge does it
# automatically when `requires_edit_mode = true` on the tool, but tools may
# also call directly for finer-grained decisions).


static func is_play_mode() -> bool:
	# In a built/exported game, is_editor_hint() is false. The bridge only
	# runs as an EditorPlugin, so this should always be true in practice,
	# but treat the non-editor case as "play" defensively.
	if not Engine.is_editor_hint():
		return true
	return EditorInterface.is_playing_scene()


static func is_edit_mode() -> bool:
	return not is_play_mode()
