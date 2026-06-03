extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates an empty Theme.tres resource, optionally inheriting another theme's
# defaults. The Theme is saved to disk and can then be assigned to a Control's
# `theme` property via set_node_resource.
#
# Property setting (colors, fonts, stylebox overrides per Control class) is
# deferred to a future tool — for v0.5.0 this is just the factory.
#
# Args:
#   path:       String (required) — res:// path for the .tres. Auto-appends
#                                   .tres if no extension.
#   base_theme: String — res:// path to a parent Theme. Optional. When present,
#                        the new theme inherits the parent's defaults via the
#                        `default_base_scale` / theme-fallback chain.
#
# Response payload:
#   path, type ("Theme"), base_theme (resolved path, or "")

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const DemoAssetsGuard = preload("res://addons/com.gladekit.mcp-bridge/services/demo_assets_guard.gd")


func _init() -> void:
	tool_name = "create_theme"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var path: String = ToolUtils.parse_path_arg(args, "path")
	if path.is_empty():
		return ToolUtils.error("path is required (res:// URI for the .tres file)")
	if path.get_extension().is_empty():
		path += ".tres"

	var guard_err := DemoAssetsGuard.check_write(path)
	if not guard_err.is_empty():
		return ToolUtils.error(guard_err)

	if FileAccess.file_exists(path):
		return ToolUtils.error_with_solutions(
			"File already exists at '%s'" % path,
			[
				"Pick a different path",
				"Or delete the file via the editor first — create_theme never overwrites in place",
			]
		)

	var theme := Theme.new()

	var base_theme_path: String = ToolUtils.parse_path_arg(args, "base_theme")
	if not base_theme_path.is_empty():
		if not FileAccess.file_exists(base_theme_path):
			return ToolUtils.error_with_solutions(
				"base_theme not found at '%s'" % base_theme_path,
				[
					"Check the path with find_asset / list_assets",
					"Or omit base_theme to start from an empty Theme",
				]
			)
		var base_res = load(base_theme_path)
		if not (base_res is Theme):
			return ToolUtils.error(
				"base_theme at '%s' loaded as %s — must be a Theme" % [
					base_theme_path,
					base_res.get_class() if base_res is Resource else "non-Resource"
				]
			)
		# Godot themes don't have a single "inherit" pointer — copy the base
		# theme's contents into the new theme so the agent gets a working
		# starting point. Subsequent edits to either don't propagate.
		theme.merge_with(base_res)

	# Ensure the target directory exists before saving.
	var dir_path := path.get_base_dir()
	if not dir_path.is_empty():
		var derr := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
		if derr != OK and derr != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (err %d)" % [dir_path, derr])

	var save_err := ResourceSaver.save(theme, path)
	if save_err != OK:
		return ToolUtils.error("ResourceSaver.save failed for '%s' (err %d)" % [path, save_err])

	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(path)

	return ToolUtils.success(
		"Created Theme at '%s'" % path,
		{
			"path": path,
			"type": "Theme",
			"base_theme": base_theme_path,
		}
	)
