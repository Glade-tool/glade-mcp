extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Sets a property on an existing material. Either:
#   (a) modify the material at a res:// path on disk (saves back via
#       ResourceSaver), OR
#   (b) assign the material to a node's MeshInstance3D and (optionally) set
#       a property on it. Pass target_node_path to do the assignment.
#
# Folds the original "assign_material_to_mesh" tool into this one per the
# Phase 3 catalog dedupe — assignment is just `surface_material_override_N`.
#
# Args:
#   material_path:    String (required) — res:// path to a .tres material.
#   property:         String — name of a property to set (albedo, metallic,
#                              roughness, emission, etc.). Optional if you
#                              only want to do assignment.
#   value:            any — value for the property.
#   target_node_path: String — when set, assigns the material to this
#                              MeshInstance3D's surface override slot.
#   surface:          int — surface override slot (default 0).
#
# Response payload:
#   material_path, applied_property (if set), assigned_to (if any)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const BackupManager = preload("res://addons/com.gladekit.mcp-bridge/services/backup_manager.gd")


func _init() -> void:
	tool_name = "set_material_property"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var material_path: String = ToolUtils.parse_path_arg(args, "material_path")
	if material_path.is_empty():
		return ToolUtils.error("material_path is required")
	if not FileAccess.file_exists(material_path):
		return ToolUtils.error_with_solutions(
			"Material does not exist at '%s'" % material_path,
			["Call create_material first", "Or check the path with find_asset / list_assets"]
		)

	var mat = load(material_path)
	if not (mat is Material):
		return ToolUtils.error("Resource at '%s' is not a Material (got %s)" % [material_path, typeof(mat)])

	var applied_property: String = ""
	if args.has("property"):
		var prop: String = ToolUtils.parse_string_arg(args, "property")
		if prop.is_empty():
			return ToolUtils.error("property cannot be empty if provided")
		var ok := _set_property(mat, prop, args.get("value"))
		if not ok:
			return ToolUtils.error("Could not set property '%s' on %s" % [prop, mat.get_class()])
		applied_property = prop
		# Back up + save the material since we modified it.
		BackupManager.backup_file(material_path)
		var save_err := ResourceSaver.save(mat, material_path)
		if save_err != OK:
			return ToolUtils.error("ResourceSaver.save failed for '%s' (err %d)" % [material_path, save_err])

	var assigned_to: String = ""
	if args.has("target_node_path"):
		var target_path: String = ToolUtils.parse_string_arg(args, "target_node_path")
		var target: Node = ToolUtils.find_node_by_path(target_path)
		if target == null:
			return ToolUtils.error("target_node_path '%s' not found" % target_path)
		if not (target is MeshInstance3D):
			return ToolUtils.error("Node '%s' is %s — material assignment only applies to MeshInstance3D" % [target_path, target.get_class()])
		var surface: int = ToolUtils.parse_int_arg(args, "surface", 0)
		var mi: MeshInstance3D = target
		mi.set_surface_override_material(surface, mat)
		assigned_to = ToolUtils.node_relative_path(mi)

	return ToolUtils.success("Updated material '%s'" % material_path, {
		"material_path": material_path,
		"applied_property": applied_property,
		"assigned_to": assigned_to,
	})


# Coerce the agent's `value` into the right type for common StandardMaterial3D
# properties. Falls back to a generic set() for everything else.
func _set_property(mat: Material, prop: String, value) -> bool:
	# Sentinel: a fully-transparent magenta no real caller would set. Lets us
	# distinguish "unparseable color" (return false) from "legitimately white".
	const SENTINEL := Color(1.0, 0.0, 1.0, 0.0)
	if mat is StandardMaterial3D:
		var std: StandardMaterial3D = mat
		match prop:
			"albedo", "albedo_color":
				var c := ToolUtils.parse_color_arg(value, SENTINEL)
				if c == SENTINEL:
					return false
				std.albedo_color = c
				return true
			"emission":
				var c2 := ToolUtils.parse_color_arg(value, SENTINEL)
				if c2 == SENTINEL:
					return false
				std.emission_enabled = true
				std.emission = c2
				return true
			"metallic":
				std.metallic = clamp(float(value), 0.0, 1.0)
				return true
			"roughness":
				std.roughness = clamp(float(value), 0.0, 1.0)
				return true
	# Generic fallback — Godot will silently drop unknown props.
	mat.set(prop, value)
	return true
