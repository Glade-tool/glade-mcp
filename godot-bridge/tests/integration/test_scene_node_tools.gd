extends GutTest

# Integration tests for the 11 Scene / Node tools. Each tool has:
#   - happy path
#   - missing-required-arg returns an error and does not crash
#   - wrong-type / wrong-value arg returns an error and does not crash
#
# Tests run a sandbox subtree under the currently edited scene root, named
# `_GladeKitTestSandbox`. Each test gets a fresh sandbox via before_each;
# after_each tears it down. The dev should open any scene before running
# these tests — preferably a throwaway scratch scene, since the test
# accumulates and removes nodes under the active scene root.

const Registry = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd")
const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const SANDBOX_NAME := "_GladeKitTestSandbox"

var _registry = null
var _sandbox: Node = null


func should_skip_script():
	# See test_signal_tools.gd::should_skip_script for the full story —
	# integration tests need editor context, GUT runs in play_custom_scene
	# where EditorInterface is unreachable, so we skip the entire file.
	if ToolUtils.get_edited_scene_root_safe() == null:
		return "requires editor context (skipped under GUT play_custom_scene; verify by driving the bridge through an MCP client with the editor open)"
	return false


func before_each() -> void:
	_registry = Registry.new()
	var scene_root := EditorInterface.get_edited_scene_root()
	# Remove any leftover sandbox from a prior crashed run.
	var leftover := scene_root.find_child(SANDBOX_NAME, false, false)
	if leftover:
		scene_root.remove_child(leftover)
		leftover.free()
	_sandbox = Node3D.new()
	_sandbox.name = SANDBOX_NAME
	scene_root.add_child(_sandbox)
	_sandbox.owner = scene_root


func after_each() -> void:
	if _sandbox != null and is_instance_valid(_sandbox):
		var parent := _sandbox.get_parent()
		if parent != null:
			parent.remove_child(_sandbox)
		_sandbox.free()
	_sandbox = null
	_registry = null


func _run(tool_name: String, args: Dictionary) -> Dictionary:
	var t = _registry.get_tool(tool_name)
	assert_not_null(t, "Tool '%s' must be registered" % tool_name)
	return t.execute(args)


# ── get_scene_tree ────────────────────────────────────────────────────────

func test_get_scene_tree_happy() -> void:
	var r := _run("get_scene_tree", {})
	assert_true(r.success)
	assert_has(r, "tree")
	assert_has(r, "node_count")
	# Flat, model-friendly rendering must be present and non-empty, and the
	# count must surface in the message so weak models don't under-report.
	assert_has(r, "tree_text")
	assert_true(r.tree_text is String and not (r.tree_text as String).is_empty())
	assert_string_contains(r.message, "node")
	# Every node the count claims should show up as a line in tree_text. The
	# sandbox guarantees at least the scene root + _GladeKitTestSandbox.
	var line_count := (r.tree_text as String).split("\n", false).size()
	assert_eq(line_count, r.node_count, "tree_text must list one line per node")
	assert_string_contains(r.tree_text, SANDBOX_NAME)


func test_get_scene_tree_reports_root_space() -> void:
	var r := _run("get_scene_tree", {})
	assert_true(r.success)
	assert_has(r, "root_space")
	# The dev scene root is a real node, so root_space must be a concrete
	# workspace classification, never "unknown".
	assert_true(["2d", "3d", "ui", "other"].has(r.root_space),
		"root_space must classify the open scene root, got '%s'" % r.root_space)


# ── 2D sprite tools ───────────────────────────────────────────────────────

func test_create_sprite_2d_no_texture_is_valid() -> void:
	var r := _run("create_sprite_2d", {"parent_path": SANDBOX_NAME, "name": "Hero"})
	assert_true(r.success)
	assert_eq(r.type, "Sprite2D")
	assert_eq(r.texture, "", "no texture arg → empty texture echo")
	assert_not_null(_sandbox.find_child("Hero", false, false))


func test_create_sprite_2d_missing_texture_errors() -> void:
	var r := _run("create_sprite_2d", {"parent_path": SANDBOX_NAME, "texture": "res://_does_not_exist_xyz.png"})
	assert_false(r.success)
	assert_true(r.has("possible_solutions"))
	# A failed texture load must NOT leave an orphaned Sprite2D in the scene.
	assert_null(_sandbox.find_child("_does_not_exist_xyz", false, false))


func test_create_animated_sprite_2d_empty_frames() -> void:
	var r := _run("create_animated_sprite_2d", {"parent_path": SANDBOX_NAME, "name": "Anim", "animation": "run", "fps": 12.0})
	assert_true(r.success)
	assert_eq(r.type, "AnimatedSprite2D")
	assert_eq(r.animation, "run")
	assert_eq(r.frame_count, 0)
	var node := _sandbox.find_child("Anim", false, false)
	assert_not_null(node)
	var sf := (node as AnimatedSprite2D).sprite_frames
	assert_not_null(sf, "SpriteFrames must be embedded even with no frames")
	assert_true(sf.has_animation("run"))
	assert_false(sf.has_animation("default"), "custom animation name should replace 'default'")


# ── TileMapLayer + Parallax2D ─────────────────────────────────────────────

func test_create_tilemap_layer_no_texture() -> void:
	var r := _run("create_tilemap_layer", {"parent_path": SANDBOX_NAME, "name": "Tiles", "tile_size": "32,32"})
	assert_true(r.success, str(r))
	assert_eq(r.type, "TileMapLayer")
	assert_eq(r.tile_size, "32,32")
	assert_eq(r.source_id, -1, "no texture → no atlas source")
	assert_eq(r.tiles_created, 0)
	var layer := _sandbox.find_child("Tiles", false, false)
	assert_not_null(layer)
	assert_not_null((layer as TileMapLayer).tile_set, "TileSet must be scaffolded")
	assert_eq((layer as TileMapLayer).tile_set.tile_size, Vector2i(32, 32))


func test_set_tilemap_cells_errors_without_source() -> void:
	var made := _run("create_tilemap_layer", {"parent_path": SANDBOX_NAME, "name": "Tiles2"})
	assert_true(made.success)
	# No atlas source (no texture) → painting must fail with guidance.
	var r := _run("set_tilemap_cells", {"node_path": String(made.node_path), "cells": [[0, 0], [1, 0]]})
	assert_false(r.success)
	assert_true(r.has("possible_solutions"))


func test_set_tilemap_cells_erase_path() -> void:
	var made := _run("create_tilemap_layer", {"parent_path": SANDBOX_NAME, "name": "Tiles3"})
	assert_true(made.success)
	# Erase doesn't need a source — it clears cells (set_cell with -1).
	var r := _run("set_tilemap_cells", {"node_path": String(made.node_path), "fill_rect": "0,0,2,2", "erase": true})
	assert_true(r.success, str(r))
	assert_eq(r.cells_set, 4)
	assert_true(r.erased)


func test_set_tilemap_cells_wrong_node_type() -> void:
	var r := _run("set_tilemap_cells", {"node_path": SANDBOX_NAME, "cells": [[0, 0]]})
	assert_false(r.success)
	assert_string_contains(r.error, "not a TileMapLayer")


func test_create_parallax_2d_no_texture() -> void:
	var r := _run("create_parallax_2d", {"parent_path": SANDBOX_NAME, "name": "BG", "scroll_scale": 0.3})
	assert_true(r.success, str(r))
	assert_eq(r.type, "Parallax2D")
	assert_eq(r.sprite_path, "", "no texture → no sprite child")
	var node := _sandbox.find_child("BG", false, false)
	assert_not_null(node)
	assert_eq((node as Parallax2D).scroll_scale, Vector2(0.3, 0.3))


func test_get_scene_tree_wrong_type_max_depth_falls_back() -> void:
	# parse_int_arg returns its default on a garbage type, so this is still
	# a successful call — just with a sensible cap.
	var r := _run("get_scene_tree", {"max_depth": "not a number"})
	assert_true(r.success)


# ── get_scene_tree response_format (v0.6.4) ───────────────────────────────

func test_get_scene_tree_format_both_is_default() -> void:
	var both := _run("get_scene_tree", {})
	assert_true(both.success)
	assert_true(both.has("tree"), "default must include tree")
	assert_true(both.has("tree_text"), "default must include tree_text")


func test_get_scene_tree_format_tree_text_only_drops_tree() -> void:
	var r := _run("get_scene_tree", {"response_format": "tree_text_only"})
	assert_true(r.success)
	assert_false(r.has("tree"), "tree_text_only must drop the nested tree")
	assert_true(r.has("tree_text"))
	assert_true(r.tree_text is String and not (r.tree_text as String).is_empty())
	# Scene metadata stays.
	assert_true(r.has("scene_path"))
	assert_true(r.has("node_count"))


func test_get_scene_tree_format_tree_only_drops_tree_text() -> void:
	var r := _run("get_scene_tree", {"response_format": "tree_only"})
	assert_true(r.success)
	assert_true(r.has("tree"))
	assert_false(r.has("tree_text"), "tree_only must drop the ASCII tree_text")
	assert_true(r.has("scene_path"))
	assert_true(r.has("node_count"))


func test_get_scene_tree_unknown_format_returns_structured_error() -> void:
	var r := _run("get_scene_tree", {"response_format": "garbage"})
	assert_false(r.success)
	assert_true(r.has("possible_solutions"))
	# At least one suggestion must name one of the valid formats so the agent
	# can self-correct on the next call.
	var solutions: Array = r.possible_solutions
	var joined: String = " ".join(solutions)
	assert_true(joined.contains("tree_text_only") or joined.contains("both"))


# ── get_node_info ─────────────────────────────────────────────────────────

func test_get_node_info_happy() -> void:
	var child := Node3D.new()
	child.name = "Probe"
	_sandbox.add_child(child)
	child.owner = EditorInterface.get_edited_scene_root()
	var r := _run("get_node_info", {"node_path": "%s/Probe" % SANDBOX_NAME})
	assert_true(r.success)
	assert_eq(r.name, "Probe")
	assert_eq(r.type, "Node3D")
	assert_has(r, "position")


func test_get_node_info_missing_arg() -> void:
	var r := _run("get_node_info", {})
	assert_false(r.success)
	assert_string_contains(r.error, "node_path is required")


func test_get_node_info_unknown_node() -> void:
	var r := _run("get_node_info", {"node_path": "DoesNotExistAnywhere_xyz"})
	assert_false(r.success)
	# Error must namedrop the requested path so the agent can tell whether
	# it's a missing node vs. a misspelled arg name.
	assert_string_contains(r.error, "DoesNotExistAnywhere_xyz")


# ── find_nodes ────────────────────────────────────────────────────────────

func test_find_nodes_happy_by_type() -> void:
	var child := Node3D.new()
	child.name = "FindMe"
	_sandbox.add_child(child)
	child.owner = EditorInterface.get_edited_scene_root()
	var r := _run("find_nodes", {"name_exact": "FindMe"})
	assert_true(r.success)
	assert_gte(r.count, 1)


func test_find_nodes_no_filters_returns_results() -> void:
	# All-pass with default cap: should return at least the sandbox itself.
	var r := _run("find_nodes", {})
	assert_true(r.success)
	assert_gte(r.count, 1)


func test_find_nodes_wrong_type_max_results_falls_back() -> void:
	var r := _run("find_nodes", {"name_exact": SANDBOX_NAME, "max_results": "huh"})
	assert_true(r.success)


# ── create_node ───────────────────────────────────────────────────────────

func test_create_node_happy() -> void:
	var r := _run("create_node", {
		"type": "Node3D",
		"name": "Spawned",
		"parent_path": SANDBOX_NAME,
	})
	assert_true(r.success)
	assert_eq(r.type, "Node3D")
	assert_not_null(_sandbox.find_child("Spawned", false, false))


func test_create_node_missing_type() -> void:
	var r := _run("create_node", {"name": "X"})
	assert_false(r.success)
	assert_string_contains(r.error, "type")


func test_create_node_unknown_type() -> void:
	var r := _run("create_node", {"type": "NotARealClassName"})
	assert_false(r.success)
	# Error must namedrop the class the agent typed so it can self-correct
	# (vs. assuming its `type` arg was missing).
	assert_string_contains(r.error, "NotARealClassName")


func test_create_node_uninstantiable_type() -> void:
	# Object is the root non-Node class — exists but not a Node.
	var r := _run("create_node", {"type": "Object"})
	assert_false(r.success)
	# Distinguish "not a Node" from "unknown class" — these are different
	# recovery paths for the agent.
	assert_string_contains(r.error, "Object")


# ── create_primitive_3d ───────────────────────────────────────────────────

func test_create_primitive_3d_happy_box() -> void:
	var r := _run("create_primitive_3d", {
		"primitive": "box",
		"name": "B",
		"parent_path": SANDBOX_NAME,
	})
	assert_true(r.success)
	assert_eq(r.type, "MeshInstance3D")
	assert_eq(r.mesh_type, "BoxMesh")


func test_create_primitive_3d_happy_sphere() -> void:
	var r := _run("create_primitive_3d", {
		"primitive": "sphere",
		"parent_path": SANDBOX_NAME,
	})
	assert_true(r.success)
	assert_eq(r.mesh_type, "SphereMesh")


func test_create_primitive_3d_unknown_primitive() -> void:
	var r := _run("create_primitive_3d", {
		"primitive": "dodecahedron",
		"parent_path": SANDBOX_NAME,
	})
	assert_false(r.success)
	assert_string_contains(r.error, "Unknown primitive")


func test_create_primitive_3d_parent_is_scene_root_name() -> void:
	# get_scene_tree renders the scene root flush-left, so agents routinely
	# pass the root's own name as parent_path. find_child searches descendants
	# only and would miss the root itself; the resolver must special-case it.
	var root_name := String(EditorInterface.get_edited_scene_root().name)
	var r := _run("create_primitive_3d", {
		"primitive": "box",
		"name": "RootChild",
		"parent_path": root_name,
	})
	assert_true(r.success, "naming the scene root as parent should resolve to root")
	assert_eq(r.node_path, "RootChild")


func test_create_primitive_3d_parent_path_prefixed_with_root_name() -> void:
	# Agents also prefix a scene-relative path with the root's own name
	# (e.g. "Main/_GladeKitTestSandbox"). A NodePath relative to root must not
	# include the root segment; the resolver strips a leading root-name part.
	var root_name := String(EditorInterface.get_edited_scene_root().name)
	var r := _run("create_primitive_3d", {
		"primitive": "box",
		"name": "Nested",
		"parent_path": "%s/%s" % [root_name, SANDBOX_NAME],
	})
	assert_true(r.success, "root-prefixed path should resolve under the sandbox")
	assert_eq(r.node_path, "%s/Nested" % SANDBOX_NAME)


# ── delete_node ───────────────────────────────────────────────────────────

func test_delete_node_happy() -> void:
	var child := Node3D.new()
	child.name = "DeleteMe"
	_sandbox.add_child(child)
	child.owner = EditorInterface.get_edited_scene_root()
	var r := _run("delete_node", {"node_path": "%s/DeleteMe" % SANDBOX_NAME})
	assert_true(r.success)
	assert_null(_sandbox.find_child("DeleteMe", false, false))


func test_delete_node_missing_arg() -> void:
	var r := _run("delete_node", {})
	assert_false(r.success)


func test_delete_node_root_refused() -> void:
	var r := _run("delete_node", {"node_path": ""})
	# Empty path resolves to scene root → must refuse.
	assert_false(r.success)


# ── rename_node ───────────────────────────────────────────────────────────

func test_rename_node_happy() -> void:
	var child := Node3D.new()
	child.name = "OldName"
	_sandbox.add_child(child)
	child.owner = EditorInterface.get_edited_scene_root()
	var r := _run("rename_node", {
		"node_path": "%s/OldName" % SANDBOX_NAME,
		"new_name": "NewName",
	})
	assert_true(r.success)
	assert_not_null(_sandbox.find_child("NewName", false, false))


func test_rename_node_missing_node_path() -> void:
	var r := _run("rename_node", {"new_name": "X"})
	assert_false(r.success)


func test_rename_node_empty_new_name() -> void:
	var child := Node3D.new()
	child.name = "X"
	_sandbox.add_child(child)
	child.owner = EditorInterface.get_edited_scene_root()
	var r := _run("rename_node", {
		"node_path": "%s/X" % SANDBOX_NAME,
		"new_name": "",
	})
	assert_false(r.success)


# ── duplicate_node ────────────────────────────────────────────────────────

func test_duplicate_node_happy() -> void:
	var src := Node3D.new()
	src.name = "Original"
	_sandbox.add_child(src)
	src.owner = EditorInterface.get_edited_scene_root()
	var r := _run("duplicate_node", {
		"node_path": "%s/Original" % SANDBOX_NAME,
		"new_name": "Clone",
	})
	assert_true(r.success)
	assert_not_null(_sandbox.find_child("Clone", false, false))


func test_duplicate_node_missing_arg() -> void:
	var r := _run("duplicate_node", {})
	assert_false(r.success)


func test_duplicate_node_root_refused() -> void:
	var r := _run("duplicate_node", {"node_path": ""})
	assert_false(r.success)


# ── set_node_parent ───────────────────────────────────────────────────────

func test_set_node_parent_happy() -> void:
	var n := Node3D.new()
	n.name = "Mover"
	_sandbox.add_child(n)
	n.owner = EditorInterface.get_edited_scene_root()
	var new_parent := Node3D.new()
	new_parent.name = "NewHome"
	_sandbox.add_child(new_parent)
	new_parent.owner = EditorInterface.get_edited_scene_root()
	var r := _run("set_node_parent", {
		"node_path": "%s/Mover" % SANDBOX_NAME,
		"new_parent_path": "%s/NewHome" % SANDBOX_NAME,
	})
	assert_true(r.success)
	assert_not_null(new_parent.find_child("Mover", false, false))


func test_set_node_parent_missing_args() -> void:
	var r := _run("set_node_parent", {"node_path": SANDBOX_NAME})
	assert_false(r.success)


func test_set_node_parent_self_refused() -> void:
	var r := _run("set_node_parent", {
		"node_path": SANDBOX_NAME,
		"new_parent_path": SANDBOX_NAME,
	})
	assert_false(r.success)


# ── set_node_transform ────────────────────────────────────────────────────

func test_set_node_transform_happy_3d() -> void:
	var n := Node3D.new()
	n.name = "Mover3D"
	_sandbox.add_child(n)
	n.owner = EditorInterface.get_edited_scene_root()
	var r := _run("set_node_transform", {
		"node_path": "%s/Mover3D" % SANDBOX_NAME,
		"position": "1,2,3",
		"scale": "2,2,2",
	})
	assert_true(r.success)
	assert_eq(n.position, Vector3(1, 2, 3))
	assert_eq(n.scale, Vector3(2, 2, 2))


func test_set_node_transform_missing_node_path() -> void:
	var r := _run("set_node_transform", {"position": "0,0,0"})
	assert_false(r.success)
	assert_string_contains(r.error, "node_path")


# Regression: a call with node_path but none of position/rotation/scale used to
# silently no-op (succeed without mutating anything), tricking the agent into
# thinking the transform was set. The tool now refuses such calls outright with
# a recovery hint listing the three accepted args.
func test_set_node_transform_no_components_is_refused() -> void:
	var n := Node3D.new()
	n.name = "NoOpProbe"
	_sandbox.add_child(n)
	n.owner = EditorInterface.get_edited_scene_root()
	var r := _run("set_node_transform", {
		"node_path": "%s/NoOpProbe" % SANDBOX_NAME,
	})
	assert_false(r.success, "missing all three transform components must error, not no-op")
	assert_true(r.has("possible_solutions"), "should hand the agent a recovery path")
	# Recovery hints must point at the three real parameter names so the
	# agent's next call self-corrects without further round-trips.
	var hints_text: String = "\n".join(r.possible_solutions)
	assert_string_contains(hints_text, "position")
	assert_string_contains(hints_text, "rotation")
	assert_string_contains(hints_text, "scale")


func test_set_node_transform_non_spatial_node_refused() -> void:
	var n := Node.new()  # plain Node — no transform
	n.name = "Plain"
	_sandbox.add_child(n)
	n.owner = EditorInterface.get_edited_scene_root()
	var r := _run("set_node_transform", {
		"node_path": "%s/Plain" % SANDBOX_NAME,
		"position": "1,2,3",
	})
	assert_false(r.success)
	assert_string_contains(r.error, "Node3D")


func test_set_node_transform_invalid_space() -> void:
	var n := Node3D.new()
	n.name = "BadSpace"
	_sandbox.add_child(n)
	n.owner = EditorInterface.get_edited_scene_root()
	var r := _run("set_node_transform", {
		"node_path": "%s/BadSpace" % SANDBOX_NAME,
		"space": "interplanetary",
		"position": "0,0,0",
	})
	assert_false(r.success)


# ── set_node_resource ──────────────────────────────────────────────────────

# Saves a resource to a unique res:// path so the tool can load() it like a
# real on-disk asset. Caller is responsible for _rm() afterwards.
func _save_temp_resource(res: Resource, filename: String) -> String:
	var path := "res://%s" % filename
	var err := ResourceSaver.save(res, path)
	assert_eq(err, OK, "Failed to save temp resource %s" % path)
	return path


func _rm(path: String) -> void:
	if not path.is_empty() and FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _make_mesh_instance(node_name: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	_sandbox.add_child(mi)
	mi.owner = EditorInterface.get_edited_scene_root()
	return mi


func test_set_node_resource_happy_assigns_mesh() -> void:
	var mi := _make_mesh_instance("MeshTarget")
	var mesh_path := _save_temp_resource(BoxMesh.new(), "_test_gk_box.tres")
	var r := _run("set_node_resource", {
		"node_path": "%s/MeshTarget" % SANDBOX_NAME,
		"property": "mesh",
		"resource_path": mesh_path,
	})
	assert_true(r.success, str(r))
	assert_true(mi.mesh is BoxMesh, "mesh property should now hold the BoxMesh")
	assert_eq(r.property, "mesh")
	assert_eq(r.resource_type, "BoxMesh")
	_rm(mesh_path)


func test_set_node_resource_clears_with_empty_path() -> void:
	var mi := _make_mesh_instance("MeshClear")
	mi.mesh = BoxMesh.new()
	var r := _run("set_node_resource", {
		"node_path": "%s/MeshClear" % SANDBOX_NAME,
		"property": "mesh",
		"resource_path": "",
	})
	assert_true(r.success, str(r))
	assert_null(mi.mesh, "mesh should be cleared to null")
	assert_null(r.resource_path)


func test_set_node_resource_missing_node_path() -> void:
	var r := _run("set_node_resource", {"property": "mesh", "resource_path": ""})
	assert_false(r.success)
	assert_string_contains(r.error, "node_path is required")


func test_set_node_resource_missing_resource_path_arg() -> void:
	var _mi := _make_mesh_instance("MeshNoPath")
	var r := _run("set_node_resource", {
		"node_path": "%s/MeshNoPath" % SANDBOX_NAME,
		"property": "mesh",
	})
	assert_false(r.success)
	assert_string_contains(r.error, "resource_path is required")


func test_set_node_resource_unknown_property_lists_resource_props() -> void:
	var _mi := _make_mesh_instance("MeshUnknownProp")
	var r := _run("set_node_resource", {
		"node_path": "%s/MeshUnknownProp" % SANDBOX_NAME,
		"property": "not_a_real_property",
		"resource_path": "res://whatever.tres",
	})
	assert_false(r.success)
	assert_has(r, "resource_properties")
	# MeshInstance3D exposes a resource-typed `mesh` property — it must appear
	# in the recovery hints so the agent can pick the right name.
	var names: Array = []
	for p in r.resource_properties:
		names.append(p.get("name", ""))
	assert_true(names.has("mesh"), "resource_properties should include 'mesh'")


func test_set_node_resource_non_resource_property_refused() -> void:
	var _mi := _make_mesh_instance("MeshScalarProp")
	var r := _run("set_node_resource", {
		"node_path": "%s/MeshScalarProp" % SANDBOX_NAME,
		"property": "position",  # Vector3, not a Resource
		"resource_path": "res://whatever.tres",
	})
	assert_false(r.success)
	assert_string_contains(r.error, "not resource-typed")


func test_set_node_resource_type_mismatch_refused() -> void:
	var _mi := _make_mesh_instance("MeshTypeMismatch")
	# Save a Material and try to assign it to the `mesh` property (expects Mesh).
	var mat_path := _save_temp_resource(StandardMaterial3D.new(), "_test_gk_mat.tres")
	var r := _run("set_node_resource", {
		"node_path": "%s/MeshTypeMismatch" % SANDBOX_NAME,
		"property": "mesh",
		"resource_path": mat_path,
	})
	assert_false(r.success)
	assert_string_contains(r.error, "expects Mesh")
	assert_eq(r.expected_type, "Mesh")
	_rm(mat_path)


func test_set_node_resource_nonexistent_path() -> void:
	var _mi := _make_mesh_instance("MeshNoFile")
	var r := _run("set_node_resource", {
		"node_path": "%s/MeshNoFile" % SANDBOX_NAME,
		"property": "mesh",
		"resource_path": "res://definitely_not_here_xyz.tres",
	})
	assert_false(r.success)
	assert_string_contains(r.error, "does not exist")


# ── set_node_property ──────────────────────────────────────────────────────

func _make_camera(node_name: String) -> Camera3D:
	var c := Camera3D.new()
	c.name = node_name
	_sandbox.add_child(c)
	c.owner = EditorInterface.get_edited_scene_root()
	return c


func test_set_node_property_happy_float() -> void:
	var cam := _make_camera("PropCamFloat")
	var r := _run("set_node_property", {
		"node_path": "%s/PropCamFloat" % SANDBOX_NAME,
		"property": "fov",
		"value": 55.0,
	})
	assert_true(r.success, str(r))
	assert_almost_eq(cam.fov, 55.0, 0.001)
	assert_eq(r.property, "fov")
	assert_eq(r.value_type, "float")
	assert_eq(r.value, 55.0)


func test_set_node_property_coerces_numeric_string() -> void:
	var cam := _make_camera("PropCamStr")
	var r := _run("set_node_property", {
		"node_path": "%s/PropCamStr" % SANDBOX_NAME,
		"property": "fov",
		"value": "42.5",  # arrives as a string, must coerce to float
	})
	assert_true(r.success, str(r))
	assert_almost_eq(cam.fov, 42.5, 0.001)


func test_set_node_property_happy_bool() -> void:
	var cam := _make_camera("PropCamBool")
	var r := _run("set_node_property", {
		"node_path": "%s/PropCamBool" % SANDBOX_NAME,
		"property": "current",
		"value": true,
	})
	assert_true(r.success, str(r))
	assert_true(cam.current)
	assert_eq(r.value_type, "bool")


func test_set_node_property_resolves_enum_label() -> void:
	var cam := _make_camera("PropCamEnum")
	# Camera3D.projection: Perspective:0, Orthogonal:1, Frustum:2 (implicit idx).
	var r := _run("set_node_property", {
		"node_path": "%s/PropCamEnum" % SANDBOX_NAME,
		"property": "projection",
		"value": "Orthogonal",
	})
	assert_true(r.success, str(r))
	assert_eq(cam.projection, Camera3D.PROJECTION_ORTHOGONAL)


func test_set_node_property_coerces_vector() -> void:
	var n := Node3D.new()
	n.name = "PropVec"
	_sandbox.add_child(n)
	n.owner = EditorInterface.get_edited_scene_root()
	var r := _run("set_node_property", {
		"node_path": "%s/PropVec" % SANDBOX_NAME,
		"property": "position",
		"value": "1,2,3",
	})
	assert_true(r.success, str(r))
	assert_eq(n.position, Vector3(1, 2, 3))
	# Vectors serialize back to the bridge's "x,y,z" float convention.
	assert_eq(r.value, "1.0,2.0,3.0")


func test_set_node_property_missing_value() -> void:
	var _cam := _make_camera("PropCamNoVal")
	var r := _run("set_node_property", {
		"node_path": "%s/PropCamNoVal" % SANDBOX_NAME,
		"property": "fov",
	})
	assert_false(r.success)
	assert_string_contains(r.error, "value is required")


func test_set_node_property_missing_node_path() -> void:
	var r := _run("set_node_property", {"property": "fov", "value": 1.0})
	assert_false(r.success)
	assert_string_contains(r.error, "node_path is required")


func test_set_node_property_unknown_property_lists_settable() -> void:
	var _cam := _make_camera("PropCamUnknown")
	var r := _run("set_node_property", {
		"node_path": "%s/PropCamUnknown" % SANDBOX_NAME,
		"property": "not_a_real_property",
		"value": 1,
	})
	assert_false(r.success)
	assert_has(r, "settable_properties")
	assert_true((r.settable_properties as Array).has("fov"),
		"settable_properties should include 'fov'")


func test_set_node_property_resource_property_redirects() -> void:
	var _cam := _make_camera("PropCamRes")
	# Camera3D.environment is Resource-typed — must redirect, not attempt a set.
	var r := _run("set_node_property", {
		"node_path": "%s/PropCamRes" % SANDBOX_NAME,
		"property": "environment",
		"value": "res://whatever.tres",
	})
	assert_false(r.success)
	assert_string_contains(r.error, "Resource-typed")
	assert_string_contains(str(r), "set_node_resource")


func test_get_node_info_include_properties() -> void:
	var cam := _make_camera("PropCamInfo")
	cam.fov = 33.0
	var r := _run("get_node_info", {
		"node_path": "%s/PropCamInfo" % SANDBOX_NAME,
		"include_properties": true,
	})
	assert_true(r.success, str(r))
	assert_has(r, "properties")
	assert_true(r.properties.has("fov"), "properties should expose scalar 'fov'")
	# Resource-typed properties are excluded — they go through set_node_resource.
	assert_false(r.properties.has("environment"),
		"properties must omit Resource-typed 'environment'")


func test_get_node_info_omits_properties_by_default() -> void:
	var _cam := _make_camera("PropCamNoInfo")
	var r := _run("get_node_info", {"node_path": "%s/PropCamNoInfo" % SANDBOX_NAME})
	assert_true(r.success, str(r))
	assert_false(r.has("properties"),
		"properties must be absent unless include_properties=true")
