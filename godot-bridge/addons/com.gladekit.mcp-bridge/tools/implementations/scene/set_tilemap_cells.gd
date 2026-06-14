extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Paints (or erases) cells on an existing TileMapLayer. Pairs with
# create_tilemap_layer: scaffold the layer + TileSet, then lay down tiles.
# Supports two ways to specify what to paint (you can use either or both):
#   - `cells`:     a list of individual cells.
#   - `fill_rect`: a rectangular region filled with one tile (floors, walls).
#
# Args:
#   node_path:  String (required) — scene-relative path to the TileMapLayer.
#   source_id:  int — TileSet atlas source id. Default: the layer's first source.
#   atlas:      "ax,ay" — default atlas tile coords for cells/fill that don't
#                         specify their own. Default: "0,0".
#   cells:      Array — each entry is one of:
#                 [x, y]                     (uses the default atlas coords)
#                 [x, y, atlas_x, atlas_y]
#                 {"x":, "y":, "atlas_x":, "atlas_y":}   (atlas_* optional)
#                 {"x":, "y":, "atlas":"ax,ay"}
#   fill_rect:  "x,y,w,h" — fill a w×h block of cells starting at (x,y) with the
#                          default atlas tile.
#   erase:      bool — when true, CLEAR the listed cells / rect instead of
#                      painting (sets them empty). Default: false.
#
# Response payload:
#   cells_set (count), erased (bool), source_id

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "set_tilemap_cells"
	requires_edit_mode = true
	min_godot_version = "4.3"


func execute(args: Dictionary) -> Dictionary:
	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	if node_path.is_empty():
		return ToolUtils.error("node_path is required (the TileMapLayer to paint)")

	var node: Node = ToolUtils.find_node_by_path(node_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found" % node_path)
	if not (node is TileMapLayer):
		return ToolUtils.error_with_solutions(
			"Node '%s' is a %s, not a TileMapLayer" % [node_path, node.get_class()],
			["Pass the path to a TileMapLayer node", "Create one first with create_tilemap_layer"]
		)
	var layer := node as TileMapLayer

	var erase: bool = ToolUtils.parse_bool_arg(args, "erase", false)

	# Resolve the atlas source. Painting needs a valid source id; erasing uses -1.
	var source_id := ToolUtils.parse_int_arg(args, "source_id", -999)
	if not erase:
		if source_id == -999:
			source_id = _first_source_id(layer)
		if source_id < 0:
			return ToolUtils.error_with_solutions(
				"No atlas source to paint from on '%s'" % node_path,
				["Pass source_id explicitly", "Recreate the layer with create_tilemap_layer(texture=...) so it has tiles"]
			)

	var default_atlas := _parse_coords(args.get("atlas"), Vector2i.ZERO)

	var painted := 0
	# Individual cells.
	for entry in _as_array(args.get("cells")):
		var parsed := _parse_cell_entry(entry, default_atlas)
		if parsed.is_empty():
			continue
		_apply(layer, parsed["coord"], erase, source_id, parsed["atlas"])
		painted += 1

	# Rectangular fill. _parse_rect returns Rect2i or null, so keep the var
	# untyped (no `:=`) to avoid inferring Variant.
	var rect = _parse_rect(args.get("fill_rect"))
	if rect != null:
		var r: Rect2i = rect
		for yy in range(r.position.y, r.position.y + r.size.y):
			for xx in range(r.position.x, r.position.x + r.size.x):
				_apply(layer, Vector2i(xx, yy), erase, source_id, default_atlas)
				painted += 1

	if painted == 0:
		return ToolUtils.error_with_solutions(
			"No cells specified",
			["Pass `cells` as a list of [x,y] or [x,y,atlas_x,atlas_y]", "Or pass `fill_rect` as 'x,y,w,h'"]
		)

	return ToolUtils.success(
		"%s %d cell%s on '%s'" % ["Erased" if erase else "Painted", painted, "" if painted == 1 else "s", node_path],
		{
			"cells_set": painted,
			"erased": erase,
			"source_id": -1 if erase else source_id,
		}
	)


func _apply(layer: TileMapLayer, coord: Vector2i, erase: bool, source_id: int, atlas: Vector2i) -> void:
	if erase:
		layer.set_cell(coord)  # source_id defaults to -1 → clears the cell
	else:
		layer.set_cell(coord, source_id, atlas)


func _first_source_id(layer: TileMapLayer) -> int:
	var ts := layer.tile_set
	if ts == null or ts.get_source_count() == 0:
		return -1
	return ts.get_source_id(0)


# ── Parsing helpers ────────────────────────────────────────────────────────

func _as_array(v) -> Array:
	if v == null:
		return []
	if v is Array:
		return v
	return []


# Parse one cells[] entry into {"coord": Vector2i, "atlas": Vector2i}, or {} if
# unrecognized.
func _parse_cell_entry(entry, default_atlas: Vector2i) -> Dictionary:
	if entry is Array:
		var a: Array = entry
		if a.size() < 2:
			return {}
		var coord := Vector2i(int(_num(a[0])), int(_num(a[1])))
		var atlas := default_atlas
		if a.size() >= 4:
			atlas = Vector2i(int(_num(a[2])), int(_num(a[3])))
		return {"coord": coord, "atlas": atlas}
	if entry is Dictionary:
		var d: Dictionary = entry
		if not (d.has("x") and d.has("y")):
			return {}
		var coord2 := Vector2i(int(_num(d["x"])), int(_num(d["y"])))
		var atlas2 := default_atlas
		if d.has("atlas_x") and d.has("atlas_y"):
			atlas2 = Vector2i(int(_num(d["atlas_x"])), int(_num(d["atlas_y"])))
		elif d.has("atlas"):
			atlas2 = _parse_coords(d["atlas"], default_atlas)
		return {"coord": coord2, "atlas": atlas2}
	return {}


# Parse "ax,ay" (string), [ax,ay] (array), or {"x":,"y":} into a Vector2i.
func _parse_coords(v, default_value: Vector2i) -> Vector2i:
	if v == null:
		return default_value
	if v is String:
		var parts: PackedStringArray = (v as String).split(",", false)
		if parts.size() < 2:
			return default_value
		return Vector2i(int(_num(parts[0])), int(_num(parts[1])))
	if v is Array and (v as Array).size() >= 2:
		return Vector2i(int(_num(v[0])), int(_num(v[1])))
	if v is Dictionary and v.has("x") and v.has("y"):
		return Vector2i(int(_num(v["x"])), int(_num(v["y"])))
	return default_value


# Parse "x,y,w,h" / [x,y,w,h] into a Rect2i, or null if absent/invalid.
func _parse_rect(v):
	var nums: Array = []
	if v is String:
		for p in (v as String).split(",", false):
			nums.append(_num(p))
	elif v is Array:
		for p in v:
			nums.append(_num(p))
	else:
		return null
	if nums.size() < 4:
		return null
	var w: int = int(nums[2])
	var h: int = int(nums[3])
	if w <= 0 or h <= 0:
		return null
	return Rect2i(int(nums[0]), int(nums[1]), w, h)


func _num(v) -> float:
	if v is float:
		return v
	if v is int:
		return float(v)
	if v is String and (v as String).strip_edges().is_valid_float():
		return float(v)
	return 0.0
