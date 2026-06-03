extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Reads Light3D-specific properties on a node — what `get_node_info` doesn't
# return because that tool is intentionally generic (transform + class +
# children only). Useful before "make it 2x brighter" or "swap to warm
# white" workflows so the agent doesn't have to guess current values.
#
# Read-only — safe during play mode.
#
# Args:
#   node_path: String (required) — scene-relative path to a Light3D.
#
# Response payload:
#   node_path, type, energy, color, shadow_enabled,
#   color_temperature, range (Omni/Spot only), spot_angle / spot_attenuation
#   (Spot only)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "get_light_info"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	if not args.has("node_path"):
		return ToolUtils.error("node_path is required")
	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	var node: Node = ToolUtils.find_node_by_path(node_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found in edited scene" % node_path)
	if not (node is Light3D):
		return ToolUtils.error("Node '%s' is %s, not a Light3D" % [node_path, node.get_class()])
	var light: Light3D = node

	var info: Dictionary = {
		"node_path": ToolUtils.node_relative_path(light),
		"type": light.get_class(),
		"energy": light.light_energy,
		"color": _color_to_hex(light.light_color),
		"shadow_enabled": light.shadow_enabled,
		"color_temperature": light.light_temperature,
	}
	if light is OmniLight3D:
		info["range"] = (light as OmniLight3D).omni_range
		info["attenuation"] = (light as OmniLight3D).omni_attenuation
	elif light is SpotLight3D:
		info["range"] = (light as SpotLight3D).spot_range
		info["spot_angle"] = (light as SpotLight3D).spot_angle
		info["spot_attenuation"] = (light as SpotLight3D).spot_attenuation

	return ToolUtils.success("Read %s state on '%s'" % [light.get_class(), node_path], info)


func _color_to_hex(c: Color) -> String:
	return "#%02x%02x%02x" % [int(round(c.r * 255)), int(round(c.g * 255)), int(round(c.b * 255))]
