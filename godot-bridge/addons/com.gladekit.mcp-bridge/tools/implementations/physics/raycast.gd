extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Casts a ray through the edited scene's physics space and reports the first
# collider it hits — the spatial-query primitive for "what's under this point",
# "is there a wall between A and B", "what would a shot from here hit". Works at
# EDIT time by querying the edited scene's world directly (no play session
# needed): the scene's collision bodies are registered in the editor's physics
# space, so intersect_ray resolves against them live.
#
# Dimension is inferred from the open scene (2D → PhysicsRayQueryParameters2D
# against world_2d; 3D → 3D against world_3d). Aim the ray either way:
#   • from + to            — explicit endpoints, OR
#   • from + direction (+ distance) — origin, a direction vector, and a length
#                                     (default 1000). `to` wins if both given.
#
# Only bodies/areas whose collision_layer intersects `collision_mask` are hit
# (default: every layer). Pass `exclude` (node paths) to ignore specific
# colliders — e.g. the node doing the casting so it doesn't hit itself.
#
# Args:
#   from:            "x,y,z" | "x,y" (required) — ray origin.
#   to:              "x,y,z" | "x,y" — ray end. Omit to use direction+distance.
#   direction:       "x,y,z" | "x,y" — ray direction (normalized internally).
#   distance:        float — ray length when using direction. Default 1000.
#   collision_mask:  int — layer bitmask to test against. Default all layers.
#   collide_with_bodies: bool — hit PhysicsBodies. Default true.
#   collide_with_areas:  bool — hit Areas. Default false.
#   hit_from_inside: bool — register a hit when `from` starts inside a shape.
#                           Default false.
#   exclude:         Array — node paths whose colliders are ignored.
#
# Response payload:
#   hit (bool), dimension ("2d"/"3d"). When hit: collider (scene-relative path),
#   collider_name, collider_class, position, normal, distance (from origin to
#   the hit). When no hit: hit=false and a null collider.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "raycast"
	# Read-only spatial query — no scene mutation, safe in edit or play mode.
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Open a scene with open_scene, or create one with create_scene"]
		)

	if not args.has("from"):
		return ToolUtils.error("from is required (ray origin as 'x,y,z' or 'x,y')")

	var space := ToolUtils.resolve_space(args)
	if space == "2d":
		return _cast_2d(root, args)
	return _cast_3d(root, args)


# ── 3D ──────────────────────────────────────────────────────────────────────
func _cast_3d(root: Node, args: Dictionary) -> Dictionary:
	var world := _world_3d(root)
	if world == null:
		return ToolUtils.error("Could not resolve a 3D physics world for the open scene")

	var from: Vector3 = ToolUtils.parse_vector3_arg(args, "from", Vector3.ZERO)
	var to: Vector3
	if args.has("to"):
		to = ToolUtils.parse_vector3_arg(args, "to", from)
	else:
		var dir: Vector3 = ToolUtils.parse_vector3_arg(args, "direction", Vector3.FORWARD)
		if dir == Vector3.ZERO:
			return ToolUtils.error("direction must be non-zero (or pass `to` instead)")
		var dist: float = ToolUtils.parse_float_arg(args, "distance", 1000.0)
		to = from + dir.normalized() * dist

	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = _mask(args)
	q.collide_with_bodies = ToolUtils.parse_bool_arg(args, "collide_with_bodies", true)
	q.collide_with_areas = ToolUtils.parse_bool_arg(args, "collide_with_areas", false)
	q.hit_from_inside = ToolUtils.parse_bool_arg(args, "hit_from_inside", false)
	q.exclude = _exclude_rids(args)

	var result: Dictionary = world.direct_space_state.intersect_ray(q)
	if result.is_empty():
		return _miss("3d", from, to)

	var pos: Vector3 = result["position"]
	var normal: Vector3 = result["normal"]
	var collider: Object = result.get("collider")
	return _hit("3d", collider, ToolUtils.serialize_vector3(pos), ToolUtils.serialize_vector3(normal), from.distance_to(pos))


# ── 2D ──────────────────────────────────────────────────────────────────────
func _cast_2d(root: Node, args: Dictionary) -> Dictionary:
	var world := _world_2d(root)
	if world == null:
		return ToolUtils.error("Could not resolve a 2D physics world for the open scene")

	var from: Vector2 = ToolUtils.parse_vector2_arg(args, "from", Vector2.ZERO)
	var to: Vector2
	if args.has("to"):
		to = ToolUtils.parse_vector2_arg(args, "to", from)
	else:
		var dir: Vector2 = ToolUtils.parse_vector2_arg(args, "direction", Vector2.RIGHT)
		if dir == Vector2.ZERO:
			return ToolUtils.error("direction must be non-zero (or pass `to` instead)")
		var dist: float = ToolUtils.parse_float_arg(args, "distance", 1000.0)
		to = from + dir.normalized() * dist

	var q := PhysicsRayQueryParameters2D.create(from, to)
	q.collision_mask = _mask(args)
	q.collide_with_bodies = ToolUtils.parse_bool_arg(args, "collide_with_bodies", true)
	q.collide_with_areas = ToolUtils.parse_bool_arg(args, "collide_with_areas", false)
	q.hit_from_inside = ToolUtils.parse_bool_arg(args, "hit_from_inside", false)
	q.exclude = _exclude_rids(args)

	var result: Dictionary = world.direct_space_state.intersect_ray(q)
	if result.is_empty():
		return _miss("2d", Vector3(from.x, from.y, 0), Vector3(to.x, to.y, 0))

	var pos: Vector2 = result["position"]
	var normal: Vector2 = result["normal"]
	var collider: Object = result.get("collider")
	return _hit("2d", collider, ToolUtils.serialize_vector2(pos), ToolUtils.serialize_vector2(normal), from.distance_to(pos))


# ── shared helpers ────────────────────────────────────────────────────────────
func _mask(args: Dictionary) -> int:
	if args.has("collision_mask"):
		return ToolUtils.parse_int_arg(args, "collision_mask", 0xFFFFFFFF)
	return 0xFFFFFFFF


# Resolve `exclude` node paths to the collider RIDs intersect_ray expects.
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


func _hit(dim: String, collider: Object, position: String, normal: String, distance: float) -> Dictionary:
	var collider_path := ""
	var collider_name := ""
	var collider_class := ""
	if collider is Node:
		collider_path = ToolUtils.node_relative_path(collider)
		collider_name = String((collider as Node).name)
		collider_class = (collider as Node).get_class()
	return ToolUtils.success(
		"Ray hit %s at %s (distance %.2f)" % [collider_name if collider_name != "" else "a collider", position, distance],
		{
			"hit": true,
			"dimension": dim,
			"collider": collider_path,
			"collider_name": collider_name,
			"collider_class": collider_class,
			"position": position,
			"normal": normal,
			"distance": distance,
		}
	)


func _miss(dim: String, from: Vector3, to: Vector3) -> Dictionary:
	return ToolUtils.success(
		"Ray hit nothing (cast through empty space)",
		{
			"hit": false,
			"dimension": dim,
			"collider": null,
		}
	)
