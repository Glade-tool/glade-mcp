extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Finds every collider overlapping a shape placed at a point — the volume-query
# counterpart of raycast (a ray is a line; this is a region). The primitive for
# "which enemies are within blast radius", "is this spot clear before I place
# something", "what's inside this trigger zone". Like raycast it runs at EDIT
# time against the open scene's physics space (no play session needed).
#
# Dimension is inferred from the open scene (2D → CircleShape2D/RectangleShape2D
# against world_2d; 3D → SphereShape3D/BoxShape3D against world_3d). Two shapes:
#   • sphere (3D) / circle (2D) — radius-based proximity (the common case).
#   • box                       — an axis-aligned region (full-size extents).
#
# Only colliders whose collision_layer intersects `collision_mask` match
# (default: every layer). Pass `exclude` (node paths) to skip specific
# colliders — e.g. the node the query is centred on. Godot's intersect_shape can
# return a collider once per overlapping shape; results are de-duplicated by
# collider here so each node appears at most once.
#
# Args:
#   position:        "x,y,z" | "x,y" (required) — centre of the query shape.
#   shape:           "sphere"|"box" (3D) or "circle"|"box" (2D). Default sphere/circle.
#   radius:          float — sphere/circle radius. Default 1.0 (3D) / 32 (2D).
#   size:            "x,y,z" | "x,y" — box full size. Default 1,1,1 (3D) / 32,32 (2D).
#   collision_mask:  int — layer bitmask to test against. Default all layers.
#   collide_with_bodies: bool — match PhysicsBodies. Default true.
#   collide_with_areas:  bool — match Areas (triggers). Default false.
#   exclude:         Array — node paths whose colliders are ignored.
#   max_results:     int — cap on colliders returned. Default 32 (clamped 1..1024).
#
# Response payload:
#   count, dimension ("2d"/"3d"), shape, colliders (list of {collider
#   (scene-relative path), collider_name, collider_class}), truncated (bool —
#   true if max_results was hit).

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "overlap_shape"
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
		return ToolUtils.error("position is required (query centre as 'x,y,z' or 'x,y')")

	var max_results: int = clampi(ToolUtils.parse_int_arg(args, "max_results", 32), 1, 1024)
	var space := ToolUtils.resolve_space(args)
	if space == "2d":
		return _query_2d(root, args, max_results)
	return _query_3d(root, args, max_results)


# ── 3D ──────────────────────────────────────────────────────────────────────
func _query_3d(root: Node, args: Dictionary, max_results: int) -> Dictionary:
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
		return ToolUtils.error_with_solutions(
			"Unknown 3D shape '%s'" % shape_kind, ["Use 'sphere' or 'box'"]
		)

	var center: Vector3 = ToolUtils.parse_vector3_arg(args, "position", Vector3.ZERO)
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis(), center)
	params.collision_mask = _mask(args)
	params.collide_with_bodies = ToolUtils.parse_bool_arg(args, "collide_with_bodies", true)
	params.collide_with_areas = ToolUtils.parse_bool_arg(args, "collide_with_areas", false)
	params.exclude = _exclude_rids(args)

	var results: Array = world.direct_space_state.intersect_shape(params, max_results)
	return _collect(results, "3d", shape_kind, max_results)


# ── 2D ──────────────────────────────────────────────────────────────────────
func _query_2d(root: Node, args: Dictionary, max_results: int) -> Dictionary:
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
		return ToolUtils.error_with_solutions(
			"Unknown 2D shape '%s'" % shape_kind, ["Use 'circle' or 'box'"]
		)

	var center: Vector2 = ToolUtils.parse_vector2_arg(args, "position", Vector2.ZERO)
	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = shape
	params.transform = Transform2D(0.0, center)
	params.collision_mask = _mask(args)
	params.collide_with_bodies = ToolUtils.parse_bool_arg(args, "collide_with_bodies", true)
	params.collide_with_areas = ToolUtils.parse_bool_arg(args, "collide_with_areas", false)
	params.exclude = _exclude_rids(args)

	var results: Array = world.direct_space_state.intersect_shape(params, max_results)
	return _collect(results, "2d", shape_kind, max_results)


# ── shared helpers ────────────────────────────────────────────────────────────
# De-duplicate intersect_shape's per-shape rows by collider and build the
# response. `truncated` flags that the raw result count reached the cap (so more
# colliders may exist beyond what was returned).
func _collect(results: Array, dim: String, shape_kind: String, max_results: int) -> Dictionary:
	var seen: Dictionary = {}
	var colliders: Array = []
	for row in results:
		var collider: Object = row.get("collider")
		if collider == null:
			continue
		var oid: int = collider.get_instance_id()
		if seen.has(oid):
			continue
		seen[oid] = true
		var entry := {"collider": "", "collider_name": "", "collider_class": ""}
		if collider is Node:
			entry["collider"] = ToolUtils.node_relative_path(collider)
			entry["collider_name"] = String((collider as Node).name)
			entry["collider_class"] = (collider as Node).get_class()
		colliders.append(entry)

	var truncated := results.size() >= max_results
	return ToolUtils.success(
		"Overlap %s found %d collider%s%s" % [
			shape_kind, colliders.size(), "" if colliders.size() == 1 else "s",
			" (truncated at max_results)" if truncated else "",
		],
		{
			"count": colliders.size(),
			"dimension": dim,
			"shape": shape_kind,
			"colliders": colliders,
			"truncated": truncated,
		}
	)


func _mask(args: Dictionary) -> int:
	if args.has("collision_mask"):
		return ToolUtils.parse_int_arg(args, "collision_mask", 0xFFFFFFFF)
	return 0xFFFFFFFF


# Resolve `exclude` node paths to the collider RIDs intersect_shape expects.
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
