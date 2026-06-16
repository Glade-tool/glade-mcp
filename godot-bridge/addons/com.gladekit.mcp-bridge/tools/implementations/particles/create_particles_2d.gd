extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates a GPUParticles2D with a fully-configured ParticleProcessMaterial in ONE
# call, picked from a small set of tuned PRESETS. Particles are the cheapest,
# highest-impact "juice" lever — an explosion on impact, sparkles on a pickup,
# smoke from a chimney, fire on a torch, a trail behind a projectile — and the
# difference between "the AI moved a sprite" and "this feels alive". Wiring a
# ParticleProcessMaterial by hand is ~15 fiddly properties (emission shape,
# direction, spread, velocity, gravity, scale, a color ramp via a GradientTexture)
# that a model re-derives slowly and inconsistently; the presets ship known-good
# values so the result looks intentional immediately.
#
# GPUParticles2D draws a small white square per particle by default (no texture
# needed), so every preset is visible the moment it's placed — assign a texture
# later for art. Particles are 2D (this is a Node2D / CanvasItem); for a 3D scene
# this tool still works but the hint steers you elsewhere.
#
# Presets (preset arg):
#   "explosion" — one-shot radial burst, orange→red, arcs down under gravity.
#                 Fire it on a hit/death. Defaults one_shot=true.
#   "sparkle"   — gentle continuous twinkle drifting up, white. Pickups, magic.
#   "smoke"     — slow rising, expanding, fading gray puffs. Chimneys, damage.
#   "fire"      — continuous upward flame, white→yellow→orange→red. Torches.
#   "trail"     — short-lived dots in WORLD space (local_coords=false) so they
#                 streak behind a moving parent. Projectiles, dashes.
#
# Args:
#   preset:      one of the above. Default "explosion".
#   name:        String — node name. Default: "<Preset>Particles".
#   parent_path: String — scene-relative parent. Default: scene root. Parent a
#                "trail" preset to the moving node you want it to streak behind.
#   position:    "x,y" — initial position. Default 0,0.
#   amount:      int — particle count override. Default: per-preset.
#   lifetime:    float — seconds each particle lives. Default: per-preset.
#   one_shot:    bool — emit a single burst then stop. Default: per-preset
#                (true for "explosion", false otherwise).
#   emitting:    bool — start emitting immediately. Default: true (so it previews
#                in the editor / fires on scene load). Set false to arm it and
#                trigger from a script (set emitting = true / call restart()).
#   color:       "#rrggbb[aa]" | "r,g,b[,a]" — override the dominant color. The
#                preset's ramp is rebuilt as this color fading to transparent.
#
# Response payload:
#   node_path, type ("GPUParticles2D"), preset, amount, lifetime, one_shot,
#   emitting, hint (only when the open scene's root is 3D)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const _PRESETS := ["explosion", "sparkle", "smoke", "fire", "trail"]


func _init() -> void:
	tool_name = "create_particles_2d"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open",
			["Call open_scene first", "Or create_scene to scaffold a new one"]
		)

	var preset: String = ToolUtils.parse_string_arg(args, "preset", "explosion").to_lower()
	if not _PRESETS.has(preset):
		return ToolUtils.error_with_solutions(
			"Unknown preset '%s'" % preset,
			["Use one of: %s" % ", ".join(_PRESETS)]
		)

	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return ToolUtils.error("Parent '%s' not found" % parent_path)

	var particles := GPUParticles2D.new()
	var mat := ParticleProcessMaterial.new()
	_apply_preset(particles, mat, preset)

	# Optional color override: rebuild the ramp as <color> → transparent so the
	# caller's intent ("red explosion") wins over the preset palette.
	if args.has("color") and args.get("color") != null:
		var c: Color = ToolUtils.parse_color_arg(args.get("color"), Color.WHITE)
		mat.color = Color(c.r, c.g, c.b, 1.0)
		mat.color_ramp = _ramp([
			[0.0, Color(c.r, c.g, c.b, 1.0)],
			[1.0, Color(c.r, c.g, c.b, 0.0)],
		])

	# Scalar overrides.
	particles.amount = maxi(1, ToolUtils.parse_int_arg(args, "amount", particles.amount))
	particles.lifetime = maxf(0.01, ToolUtils.parse_float_arg(args, "lifetime", particles.lifetime))
	particles.one_shot = ToolUtils.parse_bool_arg(args, "one_shot", particles.one_shot)
	particles.emitting = ToolUtils.parse_bool_arg(args, "emitting", true)

	particles.process_material = mat
	particles.name = ToolUtils.parse_string_arg(args, "name", preset.capitalize() + "Particles")

	parent.add_child(particles)
	particles.owner = root
	particles.position = ToolUtils.parse_vector2_arg(args, "position", Vector2.ZERO)

	var extras := {
		"node_path": ToolUtils.node_relative_path(particles),
		"type": "GPUParticles2D",
		"preset": preset,
		"amount": particles.amount,
		"lifetime": particles.lifetime,
		"one_shot": particles.one_shot,
		"emitting": particles.emitting,
	}
	var hint := ToolUtils.dimension_mismatch_note("2d", "a 3D particle setup for a 3D scene")
	if not hint.is_empty():
		extras["hint"] = hint

	return ToolUtils.success("Created GPUParticles2D '%s' (%s preset)" % [particles.name, preset], extras)


# Configure the node + process material in place for the given preset. Gravity is
# in 2D screen space: +Y is DOWN, so a negative Y gravity makes particles rise.
func _apply_preset(p: GPUParticles2D, m: ParticleProcessMaterial, preset: String) -> void:
	# Shared sensible baseline; each preset overrides what it cares about.
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.direction = Vector3(0, -1, 0)
	m.gravity = Vector3.ZERO

	match preset:
		"explosion":
			p.amount = 32
			p.lifetime = 0.7
			p.one_shot = true
			p.explosiveness = 1.0  # all particles at once = a burst, not a stream
			m.emission_sphere_radius = 4.0
			m.spread = 180.0
			m.initial_velocity_min = 120.0
			m.initial_velocity_max = 260.0
			m.gravity = Vector3(0, 320, 0)
			m.scale_min = 2.5
			m.scale_max = 4.5
			m.damping_min = 40.0
			m.damping_max = 90.0
			m.color_ramp = _ramp([
				[0.0, Color(1.0, 0.95, 0.4, 1.0)],
				[0.4, Color(1.0, 0.55, 0.12, 1.0)],
				[1.0, Color(0.7, 0.12, 0.05, 0.0)],
			])
		"sparkle":
			p.amount = 24
			p.lifetime = 1.2
			p.one_shot = false
			p.explosiveness = 0.0
			m.emission_sphere_radius = 16.0
			m.spread = 40.0
			m.initial_velocity_min = 8.0
			m.initial_velocity_max = 36.0
			m.gravity = Vector3(0, -20, 0)  # gentle upward drift
			m.scale_min = 1.0
			m.scale_max = 2.5
			m.color_ramp = _ramp([
				[0.0, Color(1.0, 1.0, 1.0, 0.0)],
				[0.3, Color(1.0, 1.0, 0.85, 1.0)],
				[1.0, Color(0.85, 0.9, 1.0, 0.0)],
			])
		"smoke":
			p.amount = 16
			p.lifetime = 2.5
			p.one_shot = false
			p.explosiveness = 0.0
			m.emission_sphere_radius = 8.0
			m.spread = 18.0
			m.initial_velocity_min = 18.0
			m.initial_velocity_max = 48.0
			m.gravity = Vector3(0, -32, 0)  # rises
			m.scale_min = 3.0
			m.scale_max = 6.0
			m.angular_velocity_min = -30.0
			m.angular_velocity_max = 30.0
			m.color_ramp = _ramp([
				[0.0, Color(0.32, 0.32, 0.34, 0.0)],
				[0.2, Color(0.34, 0.34, 0.36, 0.6)],
				[1.0, Color(0.4, 0.4, 0.42, 0.0)],
			])
		"fire":
			p.amount = 32
			p.lifetime = 0.8
			p.one_shot = false
			p.explosiveness = 0.0
			m.emission_sphere_radius = 6.0
			m.spread = 14.0
			m.initial_velocity_min = 40.0
			m.initial_velocity_max = 90.0
			m.gravity = Vector3(0, -64, 0)  # flames lick upward
			m.scale_min = 2.0
			m.scale_max = 4.0
			m.damping_min = 10.0
			m.damping_max = 30.0
			m.color_ramp = _ramp([
				[0.0, Color(1.0, 1.0, 0.75, 1.0)],
				[0.35, Color(1.0, 0.7, 0.2, 1.0)],
				[0.7, Color(1.0, 0.3, 0.08, 0.9)],
				[1.0, Color(0.5, 0.08, 0.05, 0.0)],
			])
		"trail":
			p.amount = 24
			p.lifetime = 0.5
			p.one_shot = false
			p.explosiveness = 0.0
			# World-space so the dots stay put as the parent moves, leaving a streak.
			p.local_coords = false
			m.emission_sphere_radius = 2.0
			m.spread = 180.0
			m.initial_velocity_min = 0.0
			m.initial_velocity_max = 18.0
			m.scale_min = 2.0
			m.scale_max = 3.5
			m.damping_min = 20.0
			m.damping_max = 40.0
			m.color_ramp = _ramp([
				[0.0, Color(0.6, 0.95, 1.0, 1.0)],
				[1.0, Color(0.3, 0.6, 1.0, 0.0)],
			])


# Build a GradientTexture1D from [offset, Color] stops for use as a color_ramp.
func _ramp(stops: Array) -> GradientTexture1D:
	var grad := Gradient.new()
	# Gradient starts with two default points; clear by assigning ours wholesale.
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
