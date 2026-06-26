extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Tunes an EXISTING particle system (GPUParticles2D or GPUParticles3D) after the
# fact. create_particles_2d / create_particles_3d ship a tuned PRESET, but the
# moment a user says "make the explosion bigger", "fewer sparkles", "turn it
# red", or "let it fall faster" there was no way to adjust it short of deleting
# and recreating the node — losing its placement and any hand edits. This closes
# that create -> tune loop.
#
# One tool covers BOTH dimensions: the node-level knobs (amount, lifetime,
# one_shot, …) and the ParticleProcessMaterial knobs (velocity, scale, spread,
# gravity, color) have identical names on GPUParticles2D and GPUParticles3D, so
# the same code drives both.
#
# Partial update, like set_light_properties / set_audio_player_properties: only
# the properties you pass change; everything omitted is left exactly as it was.
# Material knobs on a node whose process_material is a custom ShaderMaterial (not
# a ParticleProcessMaterial) land in `ignored_properties` with a reason, and the
# call still succeeds for whatever DID apply. A node with no process_material at
# all gets a fresh ParticleProcessMaterial the first time a material knob is set.
#
# Args:
#   node_path:     String (required) — scene-relative path to a GPUParticles2D/3D.
#   --- node knobs ---
#   amount:        int   — particle count.
#   lifetime:      float — seconds each particle lives.
#   one_shot:      bool  — emit a single burst then stop (vs. continuous).
#   emitting:      bool  — whether it is currently emitting. Set true to (re)fire.
#   explosiveness: float — 0 = a steady stream, 1 = all at once (a burst).
#   speed_scale:   float — time multiplier for the whole sim (2 = double speed).
#   --- material knobs (ParticleProcessMaterial) ---
#   velocity_min:  float — minimum initial speed.
#   velocity_max:  float — maximum initial speed.
#   scale_min:     float — minimum particle size.
#   scale_max:     float — maximum particle size.
#   spread:        float — emission cone half-angle in degrees (180 = all around).
#   gravity:       "x,y,z" — force applied each frame. 2D is screen-space (+Y is
#                  DOWN, so "0,-200,0" makes particles rise); 3D is world meters.
#   color:         "#rrggbb[aa]" | "r,g,b[,a]" — recolor: the color ramp is
#                  rebuilt as this color fading to transparent (same as create).
#
# Response payload:
#   node_path, type, applied_properties: [String],
#   ignored_properties: [{name, reason}], current: {amount, lifetime, …}

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

# Args that live on the ParticleProcessMaterial rather than the node.
const _MATERIAL_ARGS := [
	"velocity_min", "velocity_max", "scale_min", "scale_max", "spread", "gravity", "color"
]


func _init() -> void:
	tool_name = "set_particles_properties"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	if not args.has("node_path"):
		return ToolUtils.error("node_path is required")
	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	var node: Node = ToolUtils.find_node_by_path(node_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found in edited scene" % node_path)

	if not (node is GPUParticles2D or node is GPUParticles3D):
		return ToolUtils.error_with_solutions(
			"Node '%s' is %s, not a GPUParticles2D/3D" % [node_path, node.get_class()],
			[
				"Use create_particles_2d / create_particles_3d to add a particle system first",
				"Pass the path to the particle node itself, not its parent",
			]
		)

	# Untyped alias: GPUParticles2D (Node2D) and GPUParticles3D (GeometryInstance3D)
	# share no base that declares these properties, so a typed var would reject the
	# reads/writes at parse time. The guard above proves the properties exist.
	var p = node

	var applied: Array = []
	var ignored: Array = []

	# ── Node-level knobs ──
	if args.has("amount"):
		p.amount = maxi(1, ToolUtils.parse_int_arg(args, "amount", p.amount))
		applied.append("amount")
	if args.has("lifetime"):
		p.lifetime = maxf(0.01, ToolUtils.parse_float_arg(args, "lifetime", p.lifetime))
		applied.append("lifetime")
	if args.has("one_shot"):
		p.one_shot = ToolUtils.parse_bool_arg(args, "one_shot", p.one_shot)
		applied.append("one_shot")
	if args.has("emitting"):
		p.emitting = ToolUtils.parse_bool_arg(args, "emitting", p.emitting)
		applied.append("emitting")
	if args.has("explosiveness"):
		p.explosiveness = clampf(ToolUtils.parse_float_arg(args, "explosiveness", p.explosiveness), 0.0, 1.0)
		applied.append("explosiveness")
	if args.has("speed_scale"):
		p.speed_scale = maxf(0.0, ToolUtils.parse_float_arg(args, "speed_scale", p.speed_scale))
		applied.append("speed_scale")

	# ── Material-level knobs ──
	if _has_material_arg(args):
		var mat = _resolve_material(p)
		if mat == null:
			# A custom (non-ParticleProcessMaterial) process_material is present —
			# its knobs are shader uniforms we can't set by these names.
			for key in _MATERIAL_ARGS:
				if args.has(key):
					ignored.append({
						"name": key,
						"reason": "process_material is a %s, not a ParticleProcessMaterial" % p.process_material.get_class(),
					})
		else:
			_apply_material_args(mat, args, applied)

	if applied.is_empty() and ignored.is_empty():
		return ToolUtils.error_with_solutions(
			"No particle properties were provided",
			[
				"Pass at least one of: amount, lifetime, one_shot, emitting, explosiveness, speed_scale",
				"…or a material knob: velocity_min/max, scale_min/max, spread, gravity, color",
			]
		)

	var msg := "Updated %d particle propert%s on '%s'" % [applied.size(), "y" if applied.size() == 1 else "ies", node_path]
	return ToolUtils.success(msg, {
		"node_path": ToolUtils.node_relative_path(node),
		"type": node.get_class(),
		"applied_properties": applied,
		"ignored_properties": ignored,
		"current": _current_state(p),
	})


# True when any arg targets the ParticleProcessMaterial rather than the node.
func _has_material_arg(args: Dictionary) -> bool:
	for key in _MATERIAL_ARGS:
		if args.has(key):
			return true
	return false


# Return the node's ParticleProcessMaterial, creating one if absent so a bare
# particle node can still be tuned. Returns null only when a custom (shader)
# material is in the slot — those knobs aren't ours to set.
func _resolve_material(p):
	var mat = p.process_material
	if mat == null:
		mat = ParticleProcessMaterial.new()
		p.process_material = mat
		return mat
	return mat if mat is ParticleProcessMaterial else null


func _apply_material_args(mat: ParticleProcessMaterial, args: Dictionary, applied: Array) -> void:
	if args.has("velocity_min"):
		mat.initial_velocity_min = maxf(0.0, ToolUtils.parse_float_arg(args, "velocity_min", mat.initial_velocity_min))
		applied.append("velocity_min")
	if args.has("velocity_max"):
		mat.initial_velocity_max = maxf(0.0, ToolUtils.parse_float_arg(args, "velocity_max", mat.initial_velocity_max))
		applied.append("velocity_max")
	if args.has("scale_min"):
		mat.scale_min = maxf(0.0, ToolUtils.parse_float_arg(args, "scale_min", mat.scale_min))
		applied.append("scale_min")
	if args.has("scale_max"):
		mat.scale_max = maxf(0.0, ToolUtils.parse_float_arg(args, "scale_max", mat.scale_max))
		applied.append("scale_max")
	if args.has("spread"):
		mat.spread = clampf(ToolUtils.parse_float_arg(args, "spread", mat.spread), 0.0, 180.0)
		applied.append("spread")
	if args.has("gravity"):
		mat.gravity = ToolUtils.parse_vector3_arg(args, "gravity", mat.gravity)
		applied.append("gravity")
	if args.has("color") and args.get("color") != null:
		var c: Color = ToolUtils.parse_color_arg(args.get("color"), Color.WHITE)
		mat.color = Color(c.r, c.g, c.b, 1.0)
		mat.color_ramp = _ramp([
			[0.0, Color(c.r, c.g, c.b, 1.0)],
			[1.0, Color(c.r, c.g, c.b, 0.0)],
		])
		applied.append("color")


# `p` is untyped — see the alias note in execute().
func _current_state(p) -> Dictionary:
	return {
		"amount": p.amount,
		"lifetime": p.lifetime,
		"one_shot": p.one_shot,
		"emitting": p.emitting,
		"explosiveness": p.explosiveness,
		"speed_scale": p.speed_scale,
	}


# Build a GradientTexture1D from [offset, Color] stops (mirrors create_particles_*
# so a recolor here matches a recolor at create time).
func _ramp(stops: Array) -> GradientTexture1D:
	var grad := Gradient.new()
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for s in stops:
		offsets.append(float(s[0]))
		colors.append(s[1])
	grad.offsets = offsets
	grad.colors = colors
	var tex := GradientTexture1D.new()
	tex.gradient = grad
	return tex
