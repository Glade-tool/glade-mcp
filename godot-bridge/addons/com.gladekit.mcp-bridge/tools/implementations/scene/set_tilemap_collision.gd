extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Makes a TileMapLayer's tiles SOLID by adding a physics layer to its TileSet and
# a full-tile collision polygon to each tile. This is the missing link between
# "I built a tilemap level" and "the player can stand on it": a TileMapLayer
# painted with set_tilemap_cells is purely visual until its TileSet has collision,
# so a CharacterBody2D (e.g. from create_2d_controller) falls straight through the
# floor. Run this once after painting and the same tiles become collidable ground
# and walls.
#
# What it does:
#   1. Ensures the TileSet has a physics layer (adds one if none), with the given
#      collision_layer / collision_mask bits.
#   2. For every tile in every atlas source, adds a rectangle collision polygon
#      the full size of the tile (centered on the tile, matching tile_size).
#
# Args:
#   tilemap_path:    String (required) — scene-relative path to the TileMapLayer.
#   collision_layer: int — physics layer bitmask the tiles occupy. Default 1.
#   collision_mask:  int — physics layers the tiles scan. Default 1.
#   physics_layer:   int — which TileSet physics-layer index to author. Default 0
#                          (created if the TileSet has none).
#   clear_existing:  bool — remove existing collision polygons on each tile first
#                          so re-running doesn't stack duplicates. Default true.
#
# Response payload:
#   tilemap_path, physics_layer, collision_layer, collision_mask,
#   tiles_modified, sources_processed

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "set_tilemap_collision"
	requires_edit_mode = true
	# TileMapLayer was introduced in Godot 4.3 (it replaced TileMap).
	min_godot_version = "4.3"


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene first", "Or create_scene to scaffold a new one"]
		)

	var tilemap_path: String = ToolUtils.parse_string_arg(args, "tilemap_path")
	if tilemap_path.is_empty():
		return ToolUtils.error("tilemap_path is required")
	var node: Node = ToolUtils.find_node_by_path(tilemap_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found" % tilemap_path)
	if not (node is TileMapLayer):
		return ToolUtils.error_with_solutions(
			"Node '%s' is a %s, not a TileMapLayer" % [tilemap_path, node.get_class()],
			["Pass the path to a TileMapLayer", "Create one with create_tilemap_layer"]
		)

	var layer := node as TileMapLayer
	var tile_set := layer.tile_set
	if tile_set == null:
		return ToolUtils.error_with_solutions(
			"TileMapLayer '%s' has no TileSet" % tilemap_path,
			["Recreate it with create_tilemap_layer (which builds a TileSet)"]
		)

	var collision_layer: int = ToolUtils.parse_int_arg(args, "collision_layer", 1)
	var collision_mask: int = ToolUtils.parse_int_arg(args, "collision_mask", 1)
	var physics_layer: int = ToolUtils.parse_int_arg(args, "physics_layer", 0)
	var clear_existing: bool = ToolUtils.parse_bool_arg(args, "clear_existing", true)

	# Ensure the requested physics layer exists. add_physics_layer appends, so add
	# until the index is valid (almost always a single add from 0 → 1).
	while tile_set.get_physics_layers_count() <= physics_layer:
		tile_set.add_physics_layer()
	tile_set.set_physics_layer_collision_layer(physics_layer, collision_layer)
	tile_set.set_physics_layer_collision_mask(physics_layer, collision_mask)

	# Full-tile rectangle centered on the tile origin (TileData polygons are in
	# tile-local space centered at 0,0).
	var half := Vector2(tile_set.tile_size) * 0.5
	var rect := PackedVector2Array([
		Vector2(-half.x, -half.y),
		Vector2(half.x, -half.y),
		Vector2(half.x, half.y),
		Vector2(-half.x, half.y),
	])

	var tiles_modified := 0
	var sources_processed := 0
	for si in tile_set.get_source_count():
		var source_id := tile_set.get_source_id(si)
		var src := tile_set.get_source(source_id)
		if not (src is TileSetAtlasSource):
			continue
		var atlas := src as TileSetAtlasSource
		sources_processed += 1
		for ti in atlas.get_tiles_count():
			var coords := atlas.get_tile_id(ti)
			var td := atlas.get_tile_data(coords, 0)
			if td == null:
				continue
			if clear_existing:
				td.set_collision_polygons_count(physics_layer, 0)
			td.add_collision_polygon(physics_layer)
			var poly_index := td.get_collision_polygons_count(physics_layer) - 1
			td.set_collision_polygon_points(physics_layer, poly_index, rect)
			tiles_modified += 1

	if tiles_modified == 0:
		return ToolUtils.error_with_solutions(
			"TileMapLayer '%s' has a TileSet but no atlas tiles to give collision" % tilemap_path,
			[
				"Create the tilemap with a `texture` so tiles exist (create_tilemap_layer)",
				"Then paint cells with set_tilemap_cells",
			]
		)

	# Nudge the editor so the dock badge reflects the unsaved TileSet edit. The
	# polygon/physics-layer writes persist via the embedded TileSet resource on
	# save_scene regardless; this just keeps the dirty state in sync (matches
	# set_world_environment — EditorInterface.mark_scene_as_unsaved isn't public).
	if Engine.is_editor_hint():
		EditorInterface.get_edited_scene_root().notify_property_list_changed()

	return ToolUtils.success(
		"Made %d tile%s solid on '%s' (physics layer %d). The TileMapLayer's painted cells are now collidable — "
		% [tiles_modified, "" if tiles_modified == 1 else "s", tilemap_path, physics_layer]
		+ "a CharacterBody2D will stand on them. Call save_scene to persist.",
		{
			"tilemap_path": ToolUtils.node_relative_path(layer),
			"physics_layer": physics_layer,
			"collision_layer": collision_layer,
			"collision_mask": collision_mask,
			"tiles_modified": tiles_modified,
			"sources_processed": sources_processed,
		}
	)
