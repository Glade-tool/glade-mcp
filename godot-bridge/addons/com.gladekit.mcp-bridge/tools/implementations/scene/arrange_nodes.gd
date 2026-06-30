extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Positions MANY nodes into a layout pattern in ONE call — the level-building
# primitive for "lay out a row of platforms", "make a 3x3 grid of coins",
# "line these enemies up". Without it the agent must compute each position by
# hand (off-by-spacing / overlap arithmetic the model often gets wrong) and
# fire one set_node_transform per node (N round-trips). arrange_nodes does the
# math and sets every node's global position from a single anchor + spacing.
#
# Patterns:
#   row    — lay along +X (left to right).
#   column — lay along +Y (2D: down the screen; 3D: along +Z, front to back).
#   grid   — fill row-major across `columns`, wrapping to the next line:
#            index i → column i%columns (along +X), line i/columns (along the
#            column axis above).
#
# Dimension is taken from each node itself (Node2D vs Node3D); no `space` arg.
# 3D layouts lie on the X/Z ground plane (Y held at the origin's height) — the
# common case for placing props/enemies on the floor. Nodes should share a
# dimension; mix them and each is still placed by its own type, but the result
# is rarely meaningful. Control (UI) nodes are anchor-driven — they're skipped
# here; use set_control_anchors / set_control_size for UI layout.
#
# Positions are set in GLOBAL space, so nodes under different parents still line
# up in the world. The default anchor is the FIRST node's current global
# position, so "arrange these in a row" keeps the first node put and lines the
# rest up after it; pass `origin` to anchor elsewhere.
#
# Args:
#   node_paths: Array (required) — scene-relative NodePaths to arrange, IN
#                                  ORDER. Order drives placement (index 0 first).
#   pattern:    String — "row" (default) | "column" | "grid".
#   spacing:    float  — gap between adjacent node origins. Default 64 (2D) /
#                        2.0 (3D). Negative reverses direction.
#   columns:    int    — grid only: nodes per line. Default ceil(sqrt(count)).
#   origin:     "x,y" | "x,y,z" — anchor for index 0. Default: first node's
#                                 current global position.
#
# Response payload:
#   arranged (list of {node_path, position}), pattern, spacing, columns (grid
#   only), count (positioned), dimension ("2d"/"3d"), not_found (paths that
#   didn't resolve), skipped (non Node2D/Node3D paths).

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const _PATTERNS := ["row", "column", "grid"]


func _init() -> void:
	tool_name = "arrange_nodes"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene with an existing res:// path", "Call create_scene to scaffold a new one"]
		)

	var raw_paths = args.get("node_paths")
	if not (raw_paths is Array) or (raw_paths as Array).is_empty():
		return ToolUtils.error_with_solutions(
			"arrange_nodes needs a non-empty node_paths array",
			[
				"Pass the nodes to lay out, in order: node_paths=[\"Coin1\", \"Coin2\", \"Coin3\"]",
				"To move a single node, use set_node_transform instead",
			]
		)

	# Resolve the paths, partitioning into positionable nodes, unresolved paths,
	# and resolved-but-unpositionable nodes (e.g. Control / plain Node).
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
			"None of the given node_paths resolved to a Node2D/Node3D that can be positioned",
			[
				"Check the paths with get_scene_tree (not_found: %s; skipped non-positionable: %s)" % [str(not_found), str(skipped)],
				"Control (UI) nodes are anchor-driven — use set_control_anchors / set_control_size",
			]
		)

	var pattern := ToolUtils.parse_string_arg(args, "pattern", "row").strip_edges().to_lower()
	if not (pattern in _PATTERNS):
		return ToolUtils.error_with_solutions(
			"Unknown pattern '%s'" % pattern,
			["Use one of: row, column, grid"]
		)

	var first: Node = nodes[0]["node"]
	var is_3d := first is Node3D
	var spacing := ToolUtils.parse_float_arg(args, "spacing", 2.0 if is_3d else 64.0)

	var count := nodes.size()
	var columns := ToolUtils.parse_int_arg(args, "columns", 0)
	if columns <= 0:
		columns = int(ceil(sqrt(float(count))))
	columns = max(columns, 1)

	# Anchor (origin) for index 0 — default to the first node's current global
	# position. Carried as a Vector3 (z unused in 2D).
	var origin := Vector3.ZERO
	if is_3d:
		origin = (first as Node3D).global_position
		if args.has("origin"):
			origin = ToolUtils.parse_vector3_arg(args, "origin", origin)
	else:
		var op: Vector2 = (first as Node2D).global_position
		origin = Vector3(op.x, op.y, 0.0)
		if args.has("origin"):
			var ov: Vector2 = ToolUtils.parse_vector2_arg(args, "origin", op)
			origin = Vector3(ov.x, ov.y, 0.0)

	var arranged: Array = []
	for i in nodes.size():
		# Logical layout offset: `a` along the primary (X) axis, `b` along the
		# secondary axis (Y in 2D / Z in 3D).
		var a := 0.0
		var b := 0.0
		match pattern:
			"row":
				a = i * spacing
			"column":
				b = i * spacing
			"grid":
				a = float(i % columns) * spacing
				b = float(i / columns) * spacing

		var node = nodes[i]["node"]
		if node is Node3D:
			var pos3 := Vector3(origin.x + a, origin.y, origin.z + b)
			(node as Node3D).global_position = pos3
			arranged.append({"node_path": nodes[i]["path"], "position": ToolUtils.serialize_vector3(pos3)})
		else:
			var pos2 := Vector2(origin.x + a, origin.y + b)
			(node as Node2D).global_position = pos2
			arranged.append({"node_path": nodes[i]["path"], "position": "%s,%s" % [pos2.x, pos2.y]})

	var extras := {
		"arranged": arranged,
		"pattern": pattern,
		"spacing": spacing,
		"count": arranged.size(),
		"dimension": "3d" if is_3d else "2d",
		"not_found": not_found,
		"skipped": skipped,
	}
	if pattern == "grid":
		extras["columns"] = columns

	var grid_note := " across %d columns" % columns if pattern == "grid" else ""
	var miss_note := ""
	if not not_found.is_empty() or not skipped.is_empty():
		miss_note = " (%d unresolved, %d non-positionable skipped)" % [not_found.size(), skipped.size()]

	return ToolUtils.success(
		"Arranged %d node%s in a %s%s (spacing %s)%s — save the scene to persist" % [
			arranged.size(), "" if arranged.size() == 1 else "s", pattern, grid_note, spacing, miss_note,
		],
		extras
	)
