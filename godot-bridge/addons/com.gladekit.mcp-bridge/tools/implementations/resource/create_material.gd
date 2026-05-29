extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates a new StandardMaterial3D (default) or ShaderMaterial resource
# and saves it as a .tres file.
#
# Args:
#   path:        String (required) — res:// path for the .tres file. Auto-
#                                    appends .tres if no extension.
#   material_type: String — "standard" (StandardMaterial3D, default) or
#                          "shader" (ShaderMaterial, requires shader_path)
#   shader_path: String — required when material_type=shader.
#   albedo:      "r,g,b" | "#rrggbb" — initial albedo color (standard only).
#   metallic:    float (0-1) — metallic property (standard only).
#   roughness:   float (0-1) — roughness property (standard only).
#   emission:    "r,g,b" | "#rrggbb" — emission color (standard only).
#
# Response payload:
#   path, type ("StandardMaterial3D" or "ShaderMaterial")

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const DemoAssetsGuard = preload("res://addons/com.gladekit.mcp-bridge/services/demo_assets_guard.gd")


func _init() -> void:
	tool_name = "create_material"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var path: String = ToolUtils.parse_path_arg(args, "path")
	if path.is_empty():
		return ToolUtils.error("path is required")
	if path.get_extension().is_empty():
		path += ".tres"

	var guard_err := DemoAssetsGuard.check_write(path)
	if not guard_err.is_empty():
		return ToolUtils.error(guard_err)

	if FileAccess.file_exists(path):
		return ToolUtils.error_with_solutions(
			"File already exists at '%s'" % path,
			["Call set_material_property to modify the existing material", "Or pick a different path"]
		)

	var mat_type: String = ToolUtils.parse_string_arg(args, "material_type", "standard").to_lower()
	var material: Material
	if mat_type == "shader":
		var shader_path: String = ToolUtils.parse_path_arg(args, "shader_path")
		if shader_path.is_empty():
			return ToolUtils.error("shader_path is required when material_type='shader'")
		var shader := load(shader_path)
		if not (shader is Shader):
			return ToolUtils.error("'%s' did not load as a Shader resource" % shader_path)
		var sm := ShaderMaterial.new()
		sm.shader = shader
		material = sm
	else:
		var std := StandardMaterial3D.new()
		_apply_standard_properties(std, args)
		material = std

	# Ensure parent dir exists.
	var dir_path := path.get_base_dir()
	if not dir_path.is_empty():
		var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
		if err != OK and err != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (err %d)" % [dir_path, err])

	var save_err := ResourceSaver.save(material, path)
	if save_err != OK:
		return ToolUtils.error("ResourceSaver.save failed for '%s' (err %d)" % [path, save_err])

	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(path)

	return ToolUtils.success("Created %s at '%s'" % [material.get_class(), path], {
		"path": path,
		"type": material.get_class(),
	})


func _apply_standard_properties(m: StandardMaterial3D, args: Dictionary) -> void:
	if args.has("albedo"):
		var c = _color_from(args["albedo"])  # untyped: _color_from returns Color or null
		if c != null:
			m.albedo_color = c
	if args.has("emission"):
		var c2 = _color_from(args["emission"])  # untyped: _color_from returns Color or null
		if c2 != null:
			m.emission_enabled = true
			m.emission = c2
	if args.has("metallic"):
		m.metallic = clamp(ToolUtils.parse_float_arg(args, "metallic", 0.0), 0.0, 1.0)
	if args.has("roughness"):
		m.roughness = clamp(ToolUtils.parse_float_arg(args, "roughness", 1.0), 0.0, 1.0)


func _color_from(v):
	if v == null:
		return null
	if v is Color:
		return v
	if v is String:
		var s: String = (v as String).strip_edges()
		if s.is_empty():
			return null
		if s.begins_with("#"):
			return Color.html(s) if Color.html_is_valid(s) else null
		var parts: PackedStringArray = s.split(",", false)
		if parts.size() < 3:
			return null
		return Color(float(parts[0]), float(parts[1]), float(parts[2]))
	return null
