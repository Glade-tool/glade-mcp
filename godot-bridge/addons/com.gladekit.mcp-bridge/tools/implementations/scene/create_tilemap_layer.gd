extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates a TileMapLayer (Godot 4.3+, the node that replaced TileMap) with a
# ready-to-paint TileSet scaffolded from a tile atlas image. This is the
# foundation for tile-based 2D levels (platformers, top-down RPGs). Building a
# TileSet by hand is several fiddly steps (create TileSet → set tile_size → add
# a TileSetAtlasSource → set its texture + region size → create a tile per atlas
# cell); this tool does all of it so the very next call can paint cells via
# set_tilemap_cells.
#
# Args:
#   texture:     String — res:// path to a tile atlas image. Optional, but
#                         without it the layer has no tiles to paint. When given,
#                         a TileSetAtlasSource is created and every grid cell is
#                         registered as a tile.
#   tile_size:   "x,y" — tile size in pixels. Default: "16,16". Also used as the
#                         atlas region size when slicing the texture.
#   name:        String — node name. Default: "TileMapLayer".
#   parent_path: String — scene-relative parent. Default: scene root.
#   position:    "x,y" — initial position in pixels. Default: 0,0.
#
# Response payload:
#   node_path, type ("TileMapLayer"), tile_size ("x,y"), source_id (the atlas
#   source id, or -1 when no texture was given), tiles_created, atlas_grid ("x,y")

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const _DEFAULT_TILE_SIZE := Vector2i(16, 16)


func _init() -> void:
	tool_name = "create_tilemap_layer"
	requires_edit_mode = true
	# TileMapLayer was introduced in Godot 4.3 (it replaced TileMap).
	min_godot_version = "4.3"


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene with an existing res:// path", "Call create_scene to scaffold a new one"]
		)

	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return ToolUtils.error("Parent '%s' not found" % parent_path)

	var ts_size := _parse_tile_size(args)
	var tile_set := TileSet.new()
	tile_set.tile_size = ts_size

	var source_id := -1
	var tiles_created := 0
	var atlas_grid := Vector2i.ZERO

	var tex_path: String = ToolUtils.parse_path_arg(args, "texture")
	if not tex_path.is_empty():
		if not ResourceLoader.exists(tex_path):
			return ToolUtils.error_with_solutions(
				"Texture '%s' not found" % tex_path,
				["Pass a res:// path to an imported tile atlas image", "Or omit `texture` and build the TileSet later"]
			)
		var loaded = load(tex_path)
		if not (loaded is Texture2D):
			return ToolUtils.error("'%s' did not load as a Texture2D" % tex_path)
		var src := TileSetAtlasSource.new()
		src.texture = loaded
		src.texture_region_size = ts_size
		source_id = tile_set.add_source(src)
		# Register a tile for every cell in the atlas grid so they're paintable.
		atlas_grid = src.get_atlas_grid_size()
		for ty in atlas_grid.y:
			for tx in atlas_grid.x:
				src.create_tile(Vector2i(tx, ty))
				tiles_created += 1

	var layer := TileMapLayer.new()
	layer.name = ToolUtils.parse_string_arg(args, "name", "TileMapLayer")
	layer.tile_set = tile_set

	parent.add_child(layer)
	layer.owner = root
	layer.position = ToolUtils.parse_vector2_arg(args, "position", Vector2.ZERO)

	return ToolUtils.success(
		"Created TileMapLayer '%s' (%d tile%s)" % [layer.name, tiles_created, "" if tiles_created == 1 else "s"],
		{
			"node_path": ToolUtils.node_relative_path(layer),
			"type": "TileMapLayer",
			"tile_size": "%d,%d" % [ts_size.x, ts_size.y],
			"source_id": source_id,
			"tiles_created": tiles_created,
			"atlas_grid": "%d,%d" % [atlas_grid.x, atlas_grid.y],
		}
	)


func _parse_tile_size(args: Dictionary) -> Vector2i:
	var v := ToolUtils.parse_vector2_arg(args, "tile_size", Vector2(_DEFAULT_TILE_SIZE))
	var x: int = int(v.x) if v.x >= 1 else _DEFAULT_TILE_SIZE.x
	var y: int = int(v.y) if v.y >= 1 else _DEFAULT_TILE_SIZE.y
	return Vector2i(x, y)
