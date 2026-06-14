extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates a new material resource and saves it as a .tres file. The `space`
# arg picks the material family — StandardMaterial3D for 3D meshes (default) or
# CanvasItemMaterial for 2D sprites/canvas items — so one tool covers both,
# matching the create_physics_body / create_light convention. A ShaderMaterial
# (material_type="shader") is dimension-agnostic and works for either.
#
# Args:
#   path:        String (required) — res:// path for the .tres file. Auto-
#                                    appends .tres if no extension.
#   space:       "2d" | "3d" — StandardMaterial3D vs CanvasItemMaterial. When
#                omitted, inferred from the open scene's root (falls back "3d").
#   material_type: String — "standard" (default; StandardMaterial3D in 3D,
#                          CanvasItemMaterial in 2D) or "shader" (ShaderMaterial,
#                          requires shader_path; ignores `space`).
#   shader_path: String — required when material_type=shader.
#   albedo:      "r,g,b" | "#rrggbb" — initial albedo color (3D standard only).
#   metallic:    float (0-1) — metallic property (3D standard only).
#   roughness:   float (0-1) — roughness property (3D standard only).
#   emission:    "r,g,b" | "#rrggbb" — emission color (3D standard only).
#   blend_mode:  String — CanvasItemMaterial blend (2D standard only):
#                "mix" (default) | "add" | "sub" | "mul" | "premul_alpha".
#   light_mode:  String — CanvasItemMaterial light interaction (2D standard only):
#                "normal" (default) | "unshaded" | "light_only".
#
# Response payload:
#   path, type ("StandardMaterial3D" | "CanvasItemMaterial" | "ShaderMaterial")

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

	# Inferred from the open scene's root when not passed: a material created
	# while editing a 2D scene defaults to CanvasItemMaterial. material_type=
	# "shader" ignores space entirely (ShaderMaterial is dimension-agnostic).
	var space: String = ToolUtils.resolve_space(args)
	if space != "2d" and space != "3d":
		return ToolUtils.error_with_solutions(
			"Unknown space '%s'" % space,
			["Use space='3d' for a StandardMaterial3D", "Use space='2d' for a CanvasItemMaterial (sprites / canvas items)"]
		)
	var is_2d: bool = space == "2d"

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
	elif is_2d:
		var cim := CanvasItemMaterial.new()
		var blend_err := _apply_canvas_item_properties(cim, args)
		if not blend_err.is_empty():
			return ToolUtils.error(blend_err)
		material = cim
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
	# Sentinel: a fully-transparent magenta no real caller would set. Lets us
	# distinguish "missing/unparseable color" (skip the assignment) from
	# "legitimately requested Color.WHITE".
	const SENTINEL := Color(1.0, 0.0, 1.0, 0.0)
	if args.has("albedo"):
		var c := ToolUtils.parse_color_arg(args["albedo"], SENTINEL)
		if c != SENTINEL:
			m.albedo_color = c
	if args.has("emission"):
		var c2 := ToolUtils.parse_color_arg(args["emission"], SENTINEL)
		if c2 != SENTINEL:
			m.emission_enabled = true
			m.emission = c2
	if args.has("metallic"):
		m.metallic = clamp(ToolUtils.parse_float_arg(args, "metallic", 0.0), 0.0, 1.0)
	if args.has("roughness"):
		m.roughness = clamp(ToolUtils.parse_float_arg(args, "roughness", 1.0), 0.0, 1.0)


# Apply 2D CanvasItemMaterial properties. Returns "" on success or an error
# message for an unknown blend/light mode.
func _apply_canvas_item_properties(m: CanvasItemMaterial, args: Dictionary) -> String:
	if args.has("blend_mode"):
		var bm: String = ToolUtils.parse_string_arg(args, "blend_mode", "mix").to_lower()
		match bm:
			"mix", "normal":
				m.blend_mode = CanvasItemMaterial.BLEND_MODE_MIX
			"add", "additive":
				m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
			"sub", "subtract":
				m.blend_mode = CanvasItemMaterial.BLEND_MODE_SUB
			"mul", "multiply":
				m.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
			"premul_alpha", "premultiplied":
				m.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
			_:
				return "Unknown blend_mode '%s' (use mix | add | sub | mul | premul_alpha)" % bm
	if args.has("light_mode"):
		var lm: String = ToolUtils.parse_string_arg(args, "light_mode", "normal").to_lower()
		match lm:
			"normal":
				m.light_mode = CanvasItemMaterial.LIGHT_MODE_NORMAL
			"unshaded":
				m.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
			"light_only":
				m.light_mode = CanvasItemMaterial.LIGHT_MODE_LIGHT_ONLY
			_:
				return "Unknown light_mode '%s' (use normal | unshaded | light_only)" % lm
	return ""
