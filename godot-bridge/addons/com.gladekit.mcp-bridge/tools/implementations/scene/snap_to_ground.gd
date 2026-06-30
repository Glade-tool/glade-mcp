extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Drops nodes straight down onto the first surface below them — the level-dressing
# primitive for "rest all these crates on the terrain", "put the enemies on the
# floor", "snap the props down after laying them out". Pairs naturally with
# arrange_nodes: arrange a grid in the air, then snap_to_ground to seat each one
# on whatever it's over. Casts a ray downward from each node and moves the node
# to the hit point (the node's OWN colliders are excluded so it can't hit itself).
#
# Runs at EDIT time against the open scene's physics space (same mechanism as
# raycast — no play session needed). Dimension is taken from each node: 3D snaps
# along -Y, 2D snaps along +Y (screen-down). The node's ORIGIN lands on the
# surface; pass `offset` to lift it back up by the pivot-to-bottom distance so a
# centre-pivot body rests ON the ground instead of half-sunk.
#
# Args:
#   node_paths:     Array (required) — scene-relative NodePaths to snap.
#   offset:         float — distance to raise the node above the hit surface
#                           along the up axis (account for pivot-to-bottom).
#                           Default 0 (origin sits exactly on the surface).
#   max_distance:   float — how far down to search for ground. Default 1000.
#   collision_mask: int — layers that count as ground. Default all layers.
#
# Response payload:
#   snapped (list of {node_path, position, surface, distance}), missed (paths
#   with no ground below — left unmoved), not_found (paths that didn't resolve),
#   skipped (non Node2D/Node3D), count (snapped), dimension ("2d"/"3d").

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "snap_to_ground"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Open a scene with open_scene, or create one with create_scene"]
		)

	var raw_paths = args.get("node_paths")
	if not (raw_paths is Array) or (raw_paths as Array).is_empty():
		return ToolUtils.error_with_solutions(
			"snap_to_ground needs a non-empty node_paths array",
			["Pass the nodes to drop: node_paths=[\"Crate1\", \"Crate2\"]"]
		)

	# Partition into positionable nodes, unresolved paths, and unpositionable nodes.
	var nodes: Array = []
	var not_found: Array = []
	var skipped: Array = []
	for rp in raw_paths:
		var p := str(rp).strip_edges()
		if p.is_empty():
			continue
		var n: Node = ToolUtils.find_node_by_path(p)
		if n == null:
			not_found.append(p)
		elif n is Node2D or n is Node3D:
			nodes.append({"path": p, "node": n})
		else:
			skipped.append(p)

	if nodes.is_empty():
		return ToolUtils.error_with_solutions(
			"None of the given node_paths resolved to a Node2D/Node3D that can be moved",
			["Check the paths with get_scene_tree (not_found: %s)" % str(not_found)]
		)

	var offset: float = ToolUtils.parse_float_arg(args, "offset", 0.0)
	var max_distance: float = ToolUtils.parse_float_arg(args, "max_distance", 1000.0)
	var mask: int = ToolUtils.parse_int_arg(args, "collision_mask", 0xFFFFFFFF) if args.has("collision_mask") else 0xFFFFFFFF

	var is_3d := nodes[0]["node"] is Node3D
	if is_3d:
		return _snap_3d(root, nodes, offset, max_distance, mask, not_found, skipped)
	return _snap_2d(root, nodes, offset, max_distance, mask, not_found, skipped)


func _snap_3d(root: Node, nodes: Array, offset: float, max_distance: float, mask: int, not_found: Array, skipped: Array) -> Dictionary:
	var world := _world_3d(root)
	if world == null:
		return ToolUtils.error("Could not resolve a 3D physics world for the open scene")
	var space_state := world.direct_space_state

	var snapped: Array = []
	var missed: Array = []
	for item in nodes:
		var node = item["node"]
		if not (node is Node3D):
			skipped.append(item["path"])
			continue
		var n3: Node3D = node
		var from: Vector3 = n3.global_position
		var to: Vector3 = from + Vector3(0, -1, 0) * max_distance
		var q := PhysicsRayQueryParameters3D.create(from, to)
		q.collision_mask = mask
		q.exclude = _subtree_rids(n3)
		var hit: Dictionary = space_state.intersect_ray(q)
		if hit.is_empty():
			missed.append(item["path"])
			continue
		var surface: Vector3 = hit["position"]
		var placed := surface + Vector3(0, 1, 0) * offset
		n3.global_position = placed
		snapped.append({
			"node_path": item["path"],
			"position": ToolUtils.serialize_vector3(placed),
			"surface": ToolUtils.serialize_vector3(surface),
			"distance": from.distance_to(surface),
		})

	return _result("3d", snapped, missed, not_found, skipped)


func _snap_2d(root: Node, nodes: Array, offset: float, max_distance: float, mask: int, not_found: Array, skipped: Array) -> Dictionary:
	var world := _world_2d(root)
	if world == null:
		return ToolUtils.error("Could not resolve a 2D physics world for the open scene")
	var space_state := world.direct_space_state

	var snapped: Array = []
	var missed: Array = []
	for item in nodes:
		var node = item["node"]
		if not (node is Node2D):
			skipped.append(item["path"])
			continue
		var n2: Node2D = node
		var from: Vector2 = n2.global_position
		# Screen-down is +Y in 2D.
		var to: Vector2 = from + Vector2(0, 1) * max_distance
		var q := PhysicsRayQueryParameters2D.create(from, to)
		q.collision_mask = mask
		q.exclude = _subtree_rids(n2)
		var hit: Dictionary = space_state.intersect_ray(q)
		if hit.is_empty():
			missed.append(item["path"])
			continue
		var surface: Vector2 = hit["position"]
		# "Up" is -Y in 2D, so a positive offset raises the node toward the top.
		var placed := surface + Vector2(0, -1) * offset
		n2.global_position = placed
		snapped.append({
			"node_path": item["path"],
			"position": ToolUtils.serialize_vector2(placed),
			"surface": ToolUtils.serialize_vector2(surface),
			"distance": from.distance_to(surface),
		})

	return _result("2d", snapped, missed, not_found, skipped)


# ── shared helpers ────────────────────────────────────────────────────────────
func _result(dim: String, snapped: Array, missed: Array, not_found: Array, skipped: Array) -> Dictionary:
	var notes: Array = []
	if not missed.is_empty():
		notes.append("%d found no ground below" % missed.size())
	if not not_found.is_empty():
		notes.append("%d unresolved" % not_found.size())
	if not skipped.is_empty():
		notes.append("%d non-positionable" % skipped.size())
	var suffix := " (%s)" % ", ".join(notes) if not notes.is_empty() else ""
	return ToolUtils.success(
		"Snapped %d node%s to the ground%s — save the scene to persist" % [
			snapped.size(), "" if snapped.size() == 1 else "s", suffix,
		],
		{
			"snapped": snapped,
			"missed": missed,
			"not_found": not_found,
			"skipped": skipped,
			"count": snapped.size(),
			"dimension": dim,
		}
	)


# Collect the RIDs of every CollisionObject in `node`'s subtree (including the
# node itself) so the downward ray can't hit the very thing it's snapping.
func _subtree_rids(node: Node) -> Array[RID]:
	var rids: Array[RID] = []
	_gather_rids(node, rids)
	return rids


func _gather_rids(node: Node, rids: Array[RID]) -> void:
	if node is CollisionObject2D:
		rids.append((node as CollisionObject2D).get_rid())
	elif node is CollisionObject3D:
		rids.append((node as CollisionObject3D).get_rid())
	for child in node.get_children():
		_gather_rids(child, rids)


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
