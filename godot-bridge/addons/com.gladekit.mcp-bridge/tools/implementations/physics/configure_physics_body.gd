extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Configures an EXISTING collision object's physics behaviour — the config
# counterpart to create_physics_body (which builds body + shape). Three groups,
# all optional; only what you pass is applied:
#
#   1. Collision filtering (any CollisionObject2D/3D — bodies AND areas):
#        collision_layers        list of layer numbers 1..32 the object OCCUPIES
#        collision_mask_layers   list of layer numbers 1..32 the object SCANS
#      Passed as layer NUMBERS, not a raw bitmask — the tool packs the bits, so
#      "player on layer 2, scanning 1 and 3" is [2] / [1,3] rather than the
#      error-prone 2 / 5. This is the lever behind "coins don't collide with
#      walls", "enemies only hit the player", "bullets pass through pickups".
#
#   2. Surface material (StaticBody / RigidBody only — the classes with a
#      physics_material_override slot):
#        friction    0..1  (0 = frictionless / ice, 1 = grippy)
#        bounce      0..1  (0 = dead, 1 = fully elastic — a bouncy ball)
#        rough       bool  (combine friction by multiplication, not the default)
#        absorbent   bool  (combine bounce by multiplication)
#      A PhysicsMaterial is created (or the existing override reused) and
#      assigned. There is NO other way to set friction/bounce from the tool
#      surface — set_node_property rejects Resource-typed properties.
#
#   3. Rigid-body dynamics (RigidBody2D/3D only):
#        mass, gravity_scale (0 = float), linear_damp, angular_damp,
#        freeze (bool), lock_rotation (bool — RigidBody2D.lock_rotation, or all
#        three RigidBody3D axis_lock_angular_* for a 3D body).
#
# Properties that don't apply to the target node type (e.g. friction on a
# CharacterBody, mass on a StaticBody) are not errors — they're collected in
# `skipped` with a reason so the agent learns the constraint without the whole
# call failing.
#
# Args:
#   node_path: String (required) — target CollisionObject in the edited scene.
#   (plus any of the group fields above)
#
# Response payload:
#   node_path, type (node class), applied {…the values actually set…},
#   skipped [{property, reason}]

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const _MIN_LAYER := 1
const _MAX_LAYER := 32


func _init() -> void:
	tool_name = "configure_physics_body"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	if not args.has("node_path"):
		return ToolUtils.error("node_path is required")
	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	var node: Node = ToolUtils.find_node_by_path(node_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found" % node_path)

	# collision_layer exists on every CollisionObject2D/3D — its presence is our
	# "is this a physics node at all" gate.
	if not (&"collision_layer" in node):
		return ToolUtils.error_with_solutions(
			"Node '%s' (%s) is not a physics body or area" % [node_path, node.get_class()],
			[
				"Target a StaticBody/RigidBody/CharacterBody/Area node",
				"Create one first with create_physics_body",
			]
		)

	var applied: Dictionary = {}
	var skipped: Array = []

	# ── 1. Collision filtering ────────────────────────────────────────────────
	if args.has("collision_layers"):
		var packed := _pack_layers(args["collision_layers"])
		if not packed["invalid"].is_empty():
			return ToolUtils.error(
				"collision_layers must be numbers 1..32; got invalid %s" % str(packed["invalid"])
			)
		node.collision_layer = packed["mask"]
		applied["collision_layer"] = packed["mask"]
		applied["collision_layers"] = packed["layers"]
	if args.has("collision_mask_layers"):
		var packed_m := _pack_layers(args["collision_mask_layers"])
		if not packed_m["invalid"].is_empty():
			return ToolUtils.error(
				"collision_mask_layers must be numbers 1..32; got invalid %s" % str(packed_m["invalid"])
			)
		node.collision_mask = packed_m["mask"]
		applied["collision_mask"] = packed_m["mask"]
		applied["collision_mask_layers"] = packed_m["layers"]

	# ── 2. Surface material (friction / bounce) ───────────────────────────────
	var wants_material := (
		args.has("friction") or args.has("bounce")
		or args.has("rough") or args.has("absorbent")
	)
	if wants_material:
		if &"physics_material_override" in node:
			var pm: PhysicsMaterial = node.physics_material_override
			if pm == null:
				pm = PhysicsMaterial.new()
			if args.has("friction"):
				pm.friction = clampf(float(args["friction"]), 0.0, 1.0)
				applied["friction"] = pm.friction
			if args.has("bounce"):
				pm.bounce = clampf(float(args["bounce"]), 0.0, 1.0)
				applied["bounce"] = pm.bounce
			if args.has("rough"):
				pm.rough = _as_bool(args["rough"])
				applied["rough"] = pm.rough
			if args.has("absorbent"):
				pm.absorbent = _as_bool(args["absorbent"])
				applied["absorbent"] = pm.absorbent
			node.physics_material_override = pm
		else:
			var reason := (
				"%s has no physics_material_override (only StaticBody/RigidBody carry friction/bounce)"
				% node.get_class()
			)
			for k in ["friction", "bounce", "rough", "absorbent"]:
				if args.has(k):
					skipped.append({"property": k, "reason": reason})

	# ── 3. Rigid-body dynamics ────────────────────────────────────────────────
	_apply_number(node, args, "mass", applied, skipped)
	_apply_number(node, args, "gravity_scale", applied, skipped)
	_apply_number(node, args, "linear_damp", applied, skipped)
	_apply_number(node, args, "angular_damp", applied, skipped)
	_apply_flag(node, args, "freeze", applied, skipped)
	_apply_lock_rotation(node, args, applied, skipped)

	if applied.is_empty() and skipped.is_empty():
		return ToolUtils.error_with_solutions(
			"Nothing to configure — no recognised physics fields were passed",
			[
				"Pass collision_layers / collision_mask_layers (lists of 1..32)",
				"Pass friction / bounce (0..1) for a StaticBody/RigidBody",
				"Pass mass / gravity_scale / linear_damp / angular_damp / freeze / lock_rotation for a RigidBody",
			]
		)

	return ToolUtils.success(
		"Configured %s '%s'" % [node.get_class(), node.name],
		{"node_path": node_path, "type": node.get_class(), "applied": applied, "skipped": skipped}
	)


# ── helpers ───────────────────────────────────────────────────────────────────


# Pack a list of 1..32 layer numbers into a collision bitmask. Returns
# {mask:int, layers:Array[int] (deduped, sorted), invalid:Array}.
func _pack_layers(raw: Variant) -> Dictionary:
	var mask := 0
	var layers: Array = []
	var invalid: Array = []
	if raw is Array:
		for item in raw:
			var n := int(item) if (item is int or item is float or (item is String and item.is_valid_int())) else -9999
			if n < _MIN_LAYER or n > _MAX_LAYER:
				invalid.append(item)
			else:
				mask |= 1 << (n - 1)
				if not layers.has(n):
					layers.append(n)
	else:
		invalid.append(raw)
	layers.sort()
	return {"mask": mask, "layers": layers, "invalid": invalid}


# Set a numeric RigidBody property when the node exposes it, else record a skip.
func _apply_number(node: Node, args: Dictionary, key: String, applied: Dictionary, skipped: Array) -> void:
	if not args.has(key):
		return
	if key in node:
		node.set(key, float(args[key]))
		applied[key] = node.get(key)
	else:
		skipped.append({"property": key, "reason": "%s has no '%s'" % [node.get_class(), key]})


func _apply_flag(node: Node, args: Dictionary, key: String, applied: Dictionary, skipped: Array) -> void:
	if not args.has(key):
		return
	if key in node:
		node.set(key, _as_bool(args[key]))
		applied[key] = node.get(key)
	else:
		skipped.append({"property": key, "reason": "%s has no '%s'" % [node.get_class(), key]})


# lock_rotation is RigidBody2D.lock_rotation (a bool) but RigidBody3D expresses
# it as three axis_lock_angular_* flags — normalise both to one arg.
func _apply_lock_rotation(node: Node, args: Dictionary, applied: Dictionary, skipped: Array) -> void:
	if not args.has("lock_rotation"):
		return
	var val := _as_bool(args["lock_rotation"])
	if &"lock_rotation" in node:
		node.lock_rotation = val
		applied["lock_rotation"] = val
	elif &"axis_lock_angular_x" in node:
		node.axis_lock_angular_x = val
		node.axis_lock_angular_y = val
		node.axis_lock_angular_z = val
		applied["lock_rotation"] = val
	else:
		skipped.append({"property": "lock_rotation", "reason": "%s cannot lock rotation" % node.get_class()})


func _as_bool(v: Variant) -> bool:
	if v is bool:
		return v
	if v is int or v is float:
		return int(v) != 0
	if v is String:
		return v.to_lower() in ["true", "1", "yes"]
	return false
