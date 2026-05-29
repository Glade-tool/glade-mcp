extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Reports whether the editor is currently playing a scene, and which scene.
# Read-only — runs in any mode.
#
# Response payload:
#   is_playing:        bool
#   scene_path:        String — edited scene's res:// path (empty if untitled)
#   played_scene_path: String — for in-editor play, the scene currently running

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const EngineMode = preload("res://addons/com.gladekit.mcp-bridge/bridge/engine_mode.gd")


func _init() -> void:
	tool_name = "get_play_mode_state"
	requires_edit_mode = false


func execute(_args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	var scene_path: String = root.scene_file_path if root != null else ""
	var is_playing := EngineMode.is_play_mode()
	# EditorInterface.get_playing_scene() was added in 4.1; check via has_method
	# to stay compatible with the 4.3+ minimum without crashing on older builds.
	var played_path := ""
	if is_playing and EditorInterface.has_method("get_playing_scene"):
		played_path = String(EditorInterface.call("get_playing_scene"))
	return ToolUtils.success("Play mode state read", {
		"is_playing": is_playing,
		"scene_path": scene_path,
		"played_scene_path": played_path,
	})
