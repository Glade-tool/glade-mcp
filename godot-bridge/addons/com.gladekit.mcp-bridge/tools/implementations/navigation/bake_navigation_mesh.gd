extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Makes a 3D scene walkable: finds-or-creates a NavigationRegion3D, configures a
# NavigationMesh (cell size + agent dimensions), sources the scene's geometry,
# and bakes it synchronously. This is the foundation pathfinding needs — a
# NavigationAgent3D can only path across a region that has a baked mesh.
#
# This is a 3D-only tool (it builds Node3D-family navigation). Run it on a 2D
# scene and it refuses with a pointer rather than creating the wrong node type,
# matching how create_enemy_3d guards its dimension.
#
# Geometry sourcing (the part that trips people up): a fresh NavigationRegion3D
# bakes NOTHING unless it can find source geometry. Rather than force the caller
# to reparent their level under the region, this tool uses Godot's group-based
# sourcing — it adds the source node to a group and points the NavigationMesh at
# that group with SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN. Non-destructive: the
# level stays where it is, it just gains a group tag (saved with the scene).
#   - source_path given → that node (and its children) are the walkable geometry.
#   - source_path omitted → the whole scene is sourced (scene root joins the
#     group), so "bake navigation for my level" works with no extra args.
# PARSED_GEOMETRY_BOTH means both visual MeshInstance3D surfaces AND StaticBody3D
# collision shapes count — so a floor made with create_physics_body (a static
# body + CollisionShape3D, no visible mesh) still bakes.
#
# Args:
#   region_path:     String — scene-relative path to an existing NavigationRegion3D
#                    to re-bake. When omitted, the first NavigationRegion3D under
#                    parent_path is reused, or a new one is created.
#   region_name:     String — name for a newly created region. Default
#                    "NavigationRegion3D".
#   parent_path:     String — scene-relative parent for a new region. Default
#                    scene root.
#   source_path:     String — scene-relative node whose geometry (and children's)
#                    defines the walkable area. Default: the whole scene.
#   cell_size:       float — navmesh voxel size in metres. Smaller = more precise,
#                    slower bake. Default 0.25.
#   agent_radius:    float — how far the walkable area is shrunk from walls so an
#                    agent of this radius fits. Default 0.5.
#   agent_height:    float — minimum ceiling clearance. Default 1.5.
#   agent_max_climb: float — tallest step an agent can walk up. Default 0.25.
#   agent_max_slope: float (degrees) — steepest walkable incline. Default 45.
#
# Response payload:
#   region_path, source_path (resolved), polygon_count, vertex_count,
#   baked (bool — false with a hint when the bake produced no polygons)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

# Group the source geometry joins so the NavigationMesh can find it without the
# caller reparenting anything. Shared across regions in a scene — harmless,
# since GROUPS_WITH_CHILDREN just unions everything tagged.
const _SOURCE_GROUP := "gladekit_navigation_source"


func _init() -> void:
	tool_name = "bake_navigation_mesh"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open",
			["Call open_scene first", "Or create_scene to scaffold a new one"]
		)

	# 3D-only: a NavigationRegion3D under a 2D root is meaningless. Refuse with a
	# pointer instead of silently building the wrong family.
	if ToolUtils.resolve_space(args) == "2d":
		return ToolUtils.error_with_solutions(
			"bake_navigation_mesh builds 3D navigation, but the open scene is 2D",
			[
				"Open or create a 3D scene (Node3D root) to bake a NavigationRegion3D",
				"2D navigation (NavigationRegion2D / NavigationPolygon) is not yet supported by this tool",
			]
		)

	# Locate-or-create the region.
	var region: NavigationRegion3D = null
	var region_path: String = ToolUtils.parse_string_arg(args, "region_path")
	if not region_path.is_empty():
		var found: Node = ToolUtils.find_node_by_path(region_path)
		if found == null:
			return ToolUtils.error("Region '%s' not found in edited scene" % region_path)
		if not (found is NavigationRegion3D):
			return ToolUtils.error_with_solutions(
				"Node '%s' is %s, not a NavigationRegion3D" % [region_path, found.get_class()],
				["Omit region_path to create a new NavigationRegion3D", "Or pass the path of an existing NavigationRegion3D"]
			)
		region = found
	else:
		region = _find_region(root)

	var created_region := false
	if region == null:
		var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
		var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
		if parent == null:
			return ToolUtils.error("Parent '%s' not found" % parent_path)
		region = NavigationRegion3D.new()
		region.name = ToolUtils.parse_string_arg(args, "region_name", "NavigationRegion3D")
		parent.add_child(region)
		region.owner = root
		created_region = true

	# Resolve the source geometry node; default to the whole scene.
	var source_path: String = ToolUtils.parse_string_arg(args, "source_path")
	var source: Node = root
	if not source_path.is_empty():
		source = ToolUtils.find_node_by_path(source_path)
		if source == null:
			return ToolUtils.error("source_path '%s' not found" % source_path)
	# Reset the group across the scene first so THIS bake's source_path is
	# authoritative. Without it, an earlier whole-scene bake leaves the root
	# tagged and silently widens a later, narrower source_path bake. Each bake is
	# self-contained (the result lives on the region's navigation_mesh, not on
	# live group membership), so clearing here is safe for multi-region scenes.
	_clear_source_group(root)
	# persistent=true so the group tag is saved with the scene and re-bakes work.
	source.add_to_group(_SOURCE_GROUP, true)

	# Build and configure the NavigationMesh.
	var nav_mesh := NavigationMesh.new()
	nav_mesh.cell_size = ToolUtils.parse_float_arg(args, "cell_size", 0.25)
	nav_mesh.agent_radius = ToolUtils.parse_float_arg(args, "agent_radius", 0.5)
	nav_mesh.agent_height = ToolUtils.parse_float_arg(args, "agent_height", 1.5)
	nav_mesh.agent_max_climb = ToolUtils.parse_float_arg(args, "agent_max_climb", 0.25)
	nav_mesh.agent_max_slope = ToolUtils.parse_float_arg(args, "agent_max_slope", 45.0)
	# Parse both rendered meshes and static collision so create_physics_body
	# floors (collider, no MeshInstance) still bake. Source via the group above.
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_BOTH
	nav_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	nav_mesh.geometry_source_group_name = _SOURCE_GROUP
	region.navigation_mesh = nav_mesh

	# Bake on the main thread (false) — the bridge has no worker-thread protocol
	# for the editor API, and a small level bakes in milliseconds.
	region.bake_navigation_mesh(false)

	var polygon_count: int = nav_mesh.get_polygon_count()
	var vertex_count: int = nav_mesh.get_vertices().size()
	var baked: bool = polygon_count > 0

	var payload := {
		"region_path": ToolUtils.node_relative_path(region),
		"source_path": ToolUtils.node_relative_path(source),
		"created_region": created_region,
		"polygon_count": polygon_count,
		"vertex_count": vertex_count,
		"baked": baked,
	}
	if not baked:
		# A 0-polygon bake is the #1 "it didn't work" case — surface it loudly
		# instead of reporting a hollow success.
		payload["note"] = (
			"Bake produced 0 polygons — the source area has no walkable floor "
			+ "geometry. Add a floor (e.g. create_primitive_3d a plane, or "
			+ "create_physics_body type=static), or point source_path at the node "
			+ "that holds your level geometry, then bake again."
		)
		return ToolUtils.success("Baked NavigationRegion3D '%s' (0 polygons — see note)" % region.name, payload)

	return ToolUtils.success(
		"Baked NavigationRegion3D '%s' — %d polygons" % [region.name, polygon_count],
		payload
	)


# Remove the source-geometry group tag from the whole edited subtree, so the
# next add_to_group leaves exactly one authoritative source for this bake.
func _clear_source_group(node: Node) -> void:
	if node.is_in_group(_SOURCE_GROUP):
		node.remove_from_group(_SOURCE_GROUP)
	for child in node.get_children():
		_clear_source_group(child)


# First NavigationRegion3D in preorder, or null. Deterministic across calls so
# re-baking without region_path reuses the same region.
func _find_region(node: Node) -> NavigationRegion3D:
	if node is NavigationRegion3D:
		return node
	for child in node.get_children():
		var found := _find_region(child)
		if found != null:
			return found
	return null
