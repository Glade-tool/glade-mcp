extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Sweeps a shape along a motion vector and reports how far it travels before it
# first hits something — the MOTION query that completes the spatial-query trio
# (raycast = a line, overlap_shape = a static volume, shape_cast = a MOVING
# volume). The primitive for "how far can this body fall/move before it hits",
# "would this character fit through here", "where does a thrown box land". Like
# the other two it runs at EDIT time against the open scene's physics space (no
# play session).
#
# Dimension is inferred from the open scene (2D → circle/box vs world_2d; 3D →
# sphere/box vs world_3d). The shape starts at `position` and sweeps along
# `motion` (a vector), or along `direction` * `distance` if motion is omitted.
#
# Returns the safe fraction (0..1 of the motion the shape can travel before
# contact), the resulting travel/stop position, and — when it hits — the
# collider plus the contact point and normal (via get_rest_info at the contact).
# A clear path returns hit=false, safe_fraction=1, and the full travel.
#
# Args:
#   position:        "x,y,z" | "x,y" (required) — start centre of the shape.
#   motion:          "x,y,z" | "x,y" — sweep vector (direction AND length). Omit
#                    to use direction + distance.
#   direction:       "x,y,z" | "x,y" — sweep direction (normalized). Used when
#                    motion is omitted.
#   distance:        float — sweep length when using direction. Default 1000.
#   shape:           "sphere"|"box" (3D) or "circle"|"box" (2D). Default sphere/circle.
#   radius:          float — sphere/circle radius. Default 1.0 (3D) / 32 (2D).
#   size:            "x,y,z" | "x,y" — box full size. Default 1,1,1 / 32,32.
#   collision_mask:  int — layer bitmask to test against. Default all layers.
#   collide_with_bodies: bool — hit PhysicsBodies. Default true.
#   collide_with_areas:  bool — hit Areas. Default false.
#   exclude:         Array — node paths whose colliders are ignored.
#
# Response payload:
#   hit (bool), dimension ("2d"/"3d"), shape, safe_fraction, unsafe_fraction,
#   travel (motion * safe_fraction), stop_position (position + travel). When hit
#   and a contact is resolvable: collider (scene-relative path), collider_name,
#   collider_class, point (contact), normal.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "shape_cast"
	# Read-only spatial query — no scene mutation, safe in edit or play mode.
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Open a scene with open_scene, or create one with create_scene"]
		)

	if not args.has("position"):
		return ToolUtils.error("position is required (start centre as 'x,y,z' or 'x,y')")

	var space := ToolUtils.resolve_space(args)
	if space == "2d":
		return _cast_2d(root, args)
	return _cast_3d(root, args)


# ── 3D ──────────────────────────────────────────────────────────────────────
func _cast_3d(root: Node, args: Dictionary) -> Dictionary:
	var world := _world_3d(root)
	if world == null:
		return ToolUtils.error("Could not resolve a 3D physics world for the open scene")

	var shape_kind := ToolUtils.parse_string_arg(args, "shape", "sphere").strip_edges().to_lower()
	var shape: Shape3D
	if shape_kind == "box":
		var box := BoxShape3D.new()
		box.size = ToolUtils.parse_vector3_arg(args, "size", Vector3.ONE)
		shape = box
	elif shape_kind == "sphere":
		var sph := SphereShape3D.new()
		sph.radius = ToolUtils.parse_float_arg(args, "radius", 1.0)
		shape = sph
	else:
		return ToolUtils.error_with_solutions("Unknown 3D shape '%s'" % shape_kind, ["Use 'sphere' or 'box'"])

	var origin: Vector3 = ToolUtils.parse_vector3_arg(args, "position", Vector3.ZERO)
	var motion: Vector3
	if args.has("motion"):
		motion = ToolUtils.parse_vector3_arg(args, "motion", Vector3.ZERO)
	else:
		var dir: Vector3 = ToolUtils.parse_vector3_arg(args, "direction", Vector3.FORWARD)
		if dir == Vector3.ZERO:
			return ToolUtils.error("direction must be non-zero (or pass `motion` instead)")
		motion = dir.normalized() * ToolUtils.parse_float_arg(args, "distance", 1000.0)

	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis(), origin)
	params.motion = motion
	params.collision_mask = _mask(args)
	params.collide_with_bodies = ToolUtils.parse_bool_arg(args, "collide_with_bodies", true)
	params.collide_with_areas = ToolUtils.parse_bool_arg(args, "collide_with_areas", false)
	params.exclude = _exclude_rids(args)

	var space_state := world.direct_space_state
	var fractions: Array = space_state.cast_motion(params)
	var safe: float = fractions[0]
	var unsafe: float = fractions[1]
	var travel: Vector3 = motion * safe
	var stop: Vector3 = origin + travel
	var hit := unsafe < 1.0

	var extras := {
		"hit": hit,
		"dimension": "3d",
		"shape": shape_kind,
		"safe_fraction": safe,
		"unsafe_fraction": unsafe,
		"travel": ToolUtils.serialize_vector3(travel),
		"stop_position": ToolUtils.serialize_vector3(stop),
	}
	if hit:
		# Probe the contact at the unsafe position (where the shape overlaps).
		params.transform = Transform3D(Basis(), origin + motion * unsafe)
		var rest: Dictionary = space_state.get_rest_info(params)
		_merge_rest_3d(extras, rest)

	return ToolUtils.success(_msg(extras, safe), extras)


# ── 2D ──────────────────────────────────────────────────────────────────────
func _cast_2d(root: Node, args: Dictionary) -> Dictionary:
	var world := _world_2d(root)
	if world == null:
		return ToolUtils.error("Could not resolve a 2D physics world for the open scene")

	var shape_kind := ToolUtils.parse_string_arg(args, "shape", "circle").strip_edges().to_lower()
	var shape: Shape2D
	if shape_kind == "box":
		var rect := RectangleShape2D.new()
		rect.size = ToolUtils.parse_vector2_arg(args, "size", Vector2(32, 32))
		shape = rect
	elif shape_kind == "circle":
		var circle := CircleShape2D.new()
		circle.radius = ToolUtils.parse_float_arg(args, "radius", 32.0)
		shape = circle
	else:
		return ToolUtils.error_with_solutions("Unknown 2D shape '%s'" % shape_kind, ["Use 'circle' or 'box'"])

	var origin: Vector2 = ToolUtils.parse_vector2_arg(args, "position", Vector2.ZERO)
	var motion: Vector2
	if args.has("motion"):
		motion = ToolUtils.parse_vector2_arg(args, "motion", Vector2.ZERO)
	else:
		var dir: Vector2 = ToolUtils.parse_vector2_arg(args, "direction", Vector2.RIGHT)
		if dir == Vector2.ZERO:
			return ToolUtils.error("direction must be non-zero (or pass `motion` instead)")
		motion = dir.normalized() * ToolUtils.parse_float_arg(args, "distance", 1000.0)

	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = shape
	params.transform = Transform2D(0.0, origin)
	params.motion = motion
	params.collision_mask = _mask(args)
	params.collide_with_bodies = ToolUtils.parse_bool_arg(args, "collide_with_bodies", true)
	params.collide_with_areas = ToolUtils.parse_bool_arg(args, "collide_with_areas", false)
	params.exclude = _exclude_rids(args)

	var space_state := world.direct_space_state
	var fractions: Array = space_state.cast_motion(params)
	var safe: float = fractions[0]
	var unsafe: float = fractions[1]
	var travel: Vector2 = motion * safe
	var stop: Vector2 = origin + travel
	var hit := unsafe < 1.0

	var extras := {
		"hit": hit,
		"dimension": "2d",
		"shape": shape_kind,
		"safe_fraction": safe,
		"unsafe_fraction": unsafe,
		"travel": ToolUtils.serialize_vector2(travel),
		"stop_position": ToolUtils.serialize_vector2(stop),
	}
	if hit:
		params.transform = Transform2D(0.0, origin + motion * unsafe)
		var rest: Dictionary = space_state.get_rest_info(params)
		_merge_rest_2d(extras, rest)

	return ToolUtils.success(_msg(extras, safe), extras)


# ── shared helpers ────────────────────────────────────────────────────────────
func _merge_rest_3d(extras: Dictionary, rest: Dictionary) -> void:
	if rest.is_empty():
		return
	if rest.has("point"):
		extras["point"] = ToolUtils.serialize_vector3(rest["point"])
	if rest.has("normal"):
		extras["normal"] = ToolUtils.serialize_vector3(rest["normal"])
	_merge_collider(extras, rest.get("collider_id"))


func _merge_rest_2d(extras: Dictionary, rest: Dictionary) -> void:
	if rest.is_empty():
		return
	if rest.has("point"):
		extras["point"] = ToolUtils.serialize_vector2(rest["point"])
	if rest.has("normal"):
		extras["normal"] = ToolUtils.serialize_vector2(rest["normal"])
	_merge_collider(extras, rest.get("collider_id"))


# get_rest_info reports the collider by instance id (not the object, unlike
# intersect_ray); resolve it back to a node for the path/name/class.
func _merge_collider(extras: Dictionary, collider_id) -> void:
	if collider_id == null:
		return
	var obj = instance_from_id(int(collider_id))
	if obj is Node:
		extras["collider"] = ToolUtils.node_relative_path(obj)
		extras["collider_name"] = String((obj as Node).name)
		extras["collider_class"] = (obj as Node).get_class()


func _msg(extras: Dictionary, safe: float) -> String:
	if not extras["hit"]:
		return "Shape swept the full motion with no contact (clear path)"
	var name: String = extras.get("collider_name", "")
	return "Shape cast hit %s after %.0f%% of the motion (stops at %s)" % [
		name if name != "" else "a collider", safe * 100.0, extras["stop_position"],
	]


func _mask(args: Dictionary) -> int:
	if args.has("collision_mask"):
		return ToolUtils.parse_int_arg(args, "collision_mask", 0xFFFFFFFF)
	return 0xFFFFFFFF


# Resolve `exclude` node paths to the collider RIDs the query expects.
func _exclude_rids(args: Dictionary) -> Array[RID]:
	var rids: Array[RID] = []
	var raw = args.get("exclude")
	if not (raw is Array):
		return rids
	for entry in raw:
		var p := str(entry).strip_edges()
		if p.is_empty():
			continue
		var n: Node = ToolUtils.find_node_by_path(p)
		if n != null and n is CollisionObject2D:
			rids.append((n as CollisionObject2D).get_rid())
		elif n != null and n is CollisionObject3D:
			rids.append((n as CollisionObject3D).get_rid())
	return rids


func _world_3d(root: Node) -> World3D:
	if root is Node3D:
		return (root as Node3D).get_world_3d()
	for child in root.get_children():
		if child is Node3D:
			return (child as Node3D).get_world_3d()
	return null


func _world_2d(root: Node) -> World2D:
	if root is CanvasItem:
		return (root as CanvasItem).get_world_2d()
	for child in root.get_children():
		if child is CanvasItem:
			return (child as CanvasItem).get_world_2d()
	return null
