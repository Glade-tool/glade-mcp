extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates a GPUParticles3D with a fully-configured ParticleProcessMaterial AND a
# ready-to-see draw pass in ONE call, picked from a small set of tuned PRESETS.
# This is the 3D twin of create_particles_2d — same "cheapest, highest-impact
# juice" idea (an explosion on impact, sparkles on a pickup, smoke off a chimney,
# fire on a torch, a trail behind a projectile) but for Node3D scenes.
#
# Why this needs more than a process material: unlike GPUParticles2D (which draws
# a white square per particle for free), a GPUParticles3D renders NOTHING until it
# has a draw pass mesh. So every preset also ships a small QuadMesh + a billboarded,
# unshaded StandardMaterial3D that reads the per-particle color from the process
# material's ramp (vertex_color_use_as_albedo). The result is visible the instant
# it's placed — assign your own mesh/material later for art. Wiring all of this by
# hand is ~25 fiddly properties a model re-derives slowly and inconsistently; the
# presets ship known-good values so it looks intentional immediately.
#
# 3D differs from 2D in three ways the presets account for:
#   - Gravity is +Y-UP (in 2D, +Y is down). Rising smoke/fire use POSITIVE gravity.
#   - Velocities and emission radii are in METERS, not pixels (~2-10 vs ~100-260).
#   - Particle scale drives mesh size in world units, so values are ~1-3, not ~2-6.
#
# Presets (preset arg):
#   "explosion" — one-shot radial burst, orange→red, additive, arcs down under
#                 gravity. Fire it on a hit/death. Defaults one_shot=true.
#   "sparkle"   — gentle continuous twinkle drifting up, white, additive. Pickups.
#   "smoke"     — slow rising, expanding, fading gray puffs (alpha-blended).
#   "fire"      — continuous upward flame, white→yellow→orange→red, additive.
#   "trail"     — short-lived dots in WORLD space (local_coords=false) so they
#                 streak behind a moving parent. Projectiles, dashes.
#
# Args:
#   preset:      one of the above. Default "explosion".
#   name:        String — node name. Default: "<Preset>Particles".
#   parent_path: String — scene-relative parent. Default: scene root. Parent a
#                "trail" preset to the moving node you want it to streak behind.
#   position:    "x,y,z" — initial position. Default 0,0,0.
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
#   node_path, type ("GPUParticles3D"), preset, amount, lifetime, one_shot,
#   emitting, hint (only when the open scene's root is 2D)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const _PRESETS := ["explosion", "sparkle", "smoke", "fire", "trail"]


func _init() -> void:
	tool_name = "create_particles_3d"
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

	var particles := GPUParticles3D.new()
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
	particles.position = ToolUtils.parse_vector3_arg(args, "position", Vector3.ZERO)

	var extras := {
		"node_path": ToolUtils.node_relative_path(particles),
		"type": "GPUParticles3D",
		"preset": preset,
		"amount": particles.amount,
		"lifetime": particles.lifetime,
		"one_shot": particles.one_shot,
		"emitting": particles.emitting,
	}
	var hint := ToolUtils.dimension_mismatch_note("3d", "create_particles_2d is usually the right call")
	if not hint.is_empty():
		extras["hint"] = hint

	return ToolUtils.success("Created GPUParticles3D '%s' (%s preset)" % [particles.name, preset], extras)


# Configure the node + process material + draw pass in place for the given preset.
# Gravity is in 3D world space: +Y is UP, so a POSITIVE Y gravity makes particles
# rise (opposite of the 2D tool). Velocities/radii are in meters.
func _apply_preset(p: GPUParticles3D, m: ParticleProcessMaterial, preset: String) -> void:
	# Shared sensible baseline; each preset overrides what it cares about.
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.direction = Vector3(0, 1, 0)
	m.gravity = Vector3.ZERO

	# Default draw pass: a small billboarded quad, additive + unshaded, color from
	# the ramp. Presets that read better alpha-blended (smoke) override blend_mode.
	var quad_size := 0.25
	var blend := BaseMaterial3D.BLEND_MODE_ADD

	match preset:
		"explosion":
			p.amount = 32
			p.lifetime = 0.7
			p.one_shot = true
			p.explosiveness = 1.0  # all particles at once = a burst, not a stream
			m.emission_sphere_radius = 0.15
			m.spread = 180.0
			m.initial_velocity_min = 3.5
			m.initial_velocity_max = 8.0
			m.gravity = Vector3(0, -9.0, 0)
			m.scale_min = 1.0
			m.scale_max = 2.0
			m.damping_min = 1.5
			m.damping_max = 3.5
			quad_size = 0.3
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
			m.emission_sphere_radius = 0.5
			m.spread = 40.0
			m.initial_velocity_min = 0.3
			m.initial_velocity_max = 1.2
			m.gravity = Vector3(0, 0.6, 0)  # gentle upward drift
			m.scale_min = 0.6
			m.scale_max = 1.4
			quad_size = 0.12
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
			m.emission_sphere_radius = 0.25
			m.spread = 18.0
			m.initial_velocity_min = 0.6
			m.initial_velocity_max = 1.6
			m.gravity = Vector3(0, 1.0, 0)  # rises
			m.scale_min = 1.5
			m.scale_max = 3.0
			m.angular_velocity_min = -30.0
			m.angular_velocity_max = 30.0
			quad_size = 0.5
			blend = BaseMaterial3D.BLEND_MODE_MIX  # puffs read better alpha-blended
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
			m.emission_sphere_radius = 0.2
			m.spread = 14.0
			m.initial_velocity_min = 1.2
			m.initial_velocity_max = 2.8
			m.gravity = Vector3(0, 2.2, 0)  # flames lick upward
			m.scale_min = 1.0
			m.scale_max = 2.0
			m.damping_min = 0.4
			m.damping_max = 1.0
			quad_size = 0.3
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
			m.emission_sphere_radius = 0.08
			m.spread = 180.0
			m.initial_velocity_min = 0.0
			m.initial_velocity_max = 0.6
			m.scale_min = 0.6
			m.scale_max = 1.2
			m.damping_min = 0.8
			m.damping_max = 1.6
			quad_size = 0.15
			m.color_ramp = _ramp([
				[0.0, Color(0.6, 0.95, 1.0, 1.0)],
				[1.0, Color(0.3, 0.6, 1.0, 0.0)],
			])

	p.draw_pass_1 = _draw_mesh(quad_size, blend)


# Build the draw pass: a QuadMesh whose material is unshaded, billboarded (so the
# quads always face the camera), and reads each particle's color from the process
# material's ramp via vertex_color_use_as_albedo. Without this a GPUParticles3D is
# invisible. transparency=ALPHA so faded ramp stops actually fade.
func _draw_mesh(size: float, blend: int) -> QuadMesh:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(size, size)
	var smat := StandardMaterial3D.new()
	smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smat.blend_mode = blend
	smat.vertex_color_use_as_albedo = true
	smat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	smat.billboard_keep_scale = true
	mesh.material = smat
	return mesh


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
