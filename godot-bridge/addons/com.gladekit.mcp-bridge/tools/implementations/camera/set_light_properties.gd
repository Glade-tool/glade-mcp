extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Mutates an existing Light3D node (DirectionalLight3D / OmniLight3D /
# SpotLight3D). Sets only the properties the agent passes — omitted args
# leave existing values untouched, so "make the sun 2x brighter" is one
# call without round-tripping the other settings first.
#
# The Phase 3 catalog dedupe folded all three light subclasses into a
# single create_light tool; this is its mutating counterpart. Without it
# the agent had no way to change a light after creation (set_component_property
# is Unity-only).
#
# Class-aware validation: spot_angle is only meaningful on SpotLight3D, and
# range applies to Omni/Spot only. Wrong-class args land in
# `ignored_properties` with a reason so the call still succeeds for the
# args that DID apply (matches how set_node_resource handles partials).
#
# Args:
#   node_path:             String (required) — scene-relative path to a Light3D.
#   energy:                float            — light_energy multiplier.
#   color:                 "r,g,b" | "#rrggbb" — light_color.
#   shadow_enabled:        bool             — shadow_enabled.
#   range:                 float            — omni_range / spot_range (Omni/Spot only).
#   spot_angle:            float (degrees)  — spot_angle (Spot only).
#   spot_attenuation:      float            — spot_attenuation (Spot only).
#   color_temperature:     float (Kelvin)   — light_temperature (sets the
#                                              correlated-color-temperature mode
#                                              if a value is supplied).
#
# Response payload:
#   node_path, type, applied_properties: [String],
#   ignored_properties: [{name, reason}], current: {energy, color, ...}

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "set_light_properties"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	if not args.has("node_path"):
		return ToolUtils.error("node_path is required")
	var node: Node = ToolUtils.find_node_by_path(node_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found in edited scene" % node_path)
	if not (node is Light3D):
		return ToolUtils.error_with_solutions(
			"Node '%s' is %s, not a Light3D" % [node_path, node.get_class()],
			[
				"Use create_light to add a Light3D first",
				"For non-light props use set_node_resource (Resource) or set_node_transform (transform)",
			]
		)
	var light: Light3D = node

	var applied: Array = []
	var ignored: Array = []

	if args.has("energy"):
		light.light_energy = ToolUtils.parse_float_arg(args, "energy", light.light_energy)
		applied.append("energy")
	if args.has("color"):
		# Sentinel: a transparent-magenta no real caller would supply. Lets us
		# detect "unparseable" without conflating with a legitimate white.
		const COLOR_SENTINEL := Color(1.0, 0.0, 1.0, 0.0)
		var c := ToolUtils.parse_color_arg(args["color"], COLOR_SENTINEL)
		if c == COLOR_SENTINEL:
			ignored.append({"name": "color", "reason": "could not parse '%s' as a color" % str(args["color"])})
		else:
			light.light_color = c
			applied.append("color")
	if args.has("shadow_enabled"):
		light.shadow_enabled = ToolUtils.parse_bool_arg(args, "shadow_enabled", light.shadow_enabled)
		applied.append("shadow_enabled")

	# Range — Omni and Spot only. Property name differs per subclass.
	if args.has("range"):
		if light is OmniLight3D:
			(light as OmniLight3D).omni_range = ToolUtils.parse_float_arg(args, "range", (light as OmniLight3D).omni_range)
			applied.append("range")
		elif light is SpotLight3D:
			(light as SpotLight3D).spot_range = ToolUtils.parse_float_arg(args, "range", (light as SpotLight3D).spot_range)
			applied.append("range")
		else:
			ignored.append({"name": "range", "reason": "%s has no range — only OmniLight3D / SpotLight3D do" % light.get_class()})

	# Spot-only properties.
	if args.has("spot_angle"):
		if light is SpotLight3D:
			(light as SpotLight3D).spot_angle = ToolUtils.parse_float_arg(args, "spot_angle", (light as SpotLight3D).spot_angle)
			applied.append("spot_angle")
		else:
			ignored.append({"name": "spot_angle", "reason": "%s is not a SpotLight3D" % light.get_class()})
	if args.has("spot_attenuation"):
		if light is SpotLight3D:
			(light as SpotLight3D).spot_attenuation = ToolUtils.parse_float_arg(args, "spot_attenuation", (light as SpotLight3D).spot_attenuation)
			applied.append("spot_attenuation")
		else:
			ignored.append({"name": "spot_attenuation", "reason": "%s is not a SpotLight3D" % light.get_class()})

	# Color temperature — Godot represents this as light_temperature in Kelvin.
	# Setting any value enables the temperature-as-color path (the engine
	# multiplies temperature onto light_color); we don't expose a separate
	# "use temperature" toggle here because Godot doesn't have one (Unity does).
	if args.has("color_temperature"):
		light.light_temperature = ToolUtils.parse_float_arg(args, "color_temperature", light.light_temperature)
		applied.append("color_temperature")

	if applied.is_empty() and ignored.is_empty():
		return ToolUtils.error_with_solutions(
			"No light properties were provided",
			[
				"Pass at least one of: energy, color, shadow_enabled, range, spot_angle, spot_attenuation, color_temperature",
				"Use get_light_info to read current values first",
			]
		)

	var msg := "Updated %d light propert%s on '%s'" % [applied.size(), "y" if applied.size() == 1 else "ies", node_path]
	return ToolUtils.success(msg, {
		"node_path": ToolUtils.node_relative_path(light),
		"type": light.get_class(),
		"applied_properties": applied,
		"ignored_properties": ignored,
		"current": _current_state(light),
	})


func _current_state(light: Light3D) -> Dictionary:
	var state: Dictionary = {
		"energy": light.light_energy,
		"color": _color_to_hex(light.light_color),
		"shadow_enabled": light.shadow_enabled,
		"color_temperature": light.light_temperature,
	}
	if light is OmniLight3D:
		state["range"] = (light as OmniLight3D).omni_range
	elif light is SpotLight3D:
		state["range"] = (light as SpotLight3D).spot_range
		state["spot_angle"] = (light as SpotLight3D).spot_angle
		state["spot_attenuation"] = (light as SpotLight3D).spot_attenuation
	return state


func _color_to_hex(c: Color) -> String:
	return "#%02x%02x%02x" % [int(round(c.r * 255)), int(round(c.g * 255)), int(round(c.b * 255))]
