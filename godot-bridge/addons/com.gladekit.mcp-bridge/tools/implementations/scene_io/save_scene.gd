extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Saves the currently edited scene to disk. If the scene has never been
# saved (scene_file_path is empty), require a path argument.
#
# Args:
#   path: String — only required when saving an unsaved scene. Auto-appends .tscn.
#
# Response payload:
#   path: String — the final save location
#   was_unsaved: bool — true if this was the first save for this scene

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const BackupManager = preload("res://addons/com.gladekit.mcp-bridge/services/backup_manager.gd")


func _init() -> void:
	tool_name = "save_scene"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error("No scene is currently open")

	var existing_path: String = root.scene_file_path
	var was_unsaved := existing_path.is_empty()

	var target_path := existing_path
	if was_unsaved:
		target_path = ToolUtils.parse_path_arg(args, "path")
		if target_path.is_empty():
			return ToolUtils.error_with_solutions(
				"Scene has never been saved; path is required",
				["Pass path='res://main.tscn' (or similar)", "Or call create_scene to scaffold a new scene with a path"]
			)
		if target_path.get_extension().is_empty():
			target_path += ".tscn"

	if not was_unsaved:
		# Snapshot before overwrite so a prior version can be recovered.
		BackupManager.backup_file(target_path)

	# Save THROUGH the editor rather than writing the file directly. A bare
	# ResourceSaver.save() updates the .tscn on disk behind the editor's back,
	# so the next time the editor regains focus it sees the open scene as
	# "newer on disk" and prompts the user to reload from disk. Routing the
	# write through the editor's own save pipeline marks the open scene as
	# saved and in sync with disk, so no reload prompt appears.
	if was_unsaved:
		# First save: save_scene_as assigns the path and updates editor state.
		# It returns void, so confirm the file landed on disk afterwards.
		EditorInterface.save_scene_as(target_path, false)
		if not FileAccess.file_exists(target_path):
			return ToolUtils.error("Editor failed to save scene to '%s'" % target_path)
	else:
		# In-place save of the currently edited scene at its existing path.
		var save_err := EditorInterface.save_scene()
		if save_err != OK:
			return ToolUtils.error("Editor save_scene failed for '%s' (err %d)" % [target_path, save_err])

	return ToolUtils.success("Saved scene to '%s'" % target_path, {
		"path": target_path,
		"was_unsaved": was_unsaved,
	})
