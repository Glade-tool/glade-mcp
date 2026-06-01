extends GutTest

# Integration tests for the 10 Scene / Node tools. Each tool has:
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


func before_each() -> void:
	_registry = Registry.new()
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		pending("No edited scene open — open any scene before running integration tests")
		return
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


func test_get_scene_tree_wrong_type_max_depth_falls_back() -> void:
	# parse_int_arg returns its default on a garbage type, so this is still
	# a successful call — just with a sensible cap.
	var r := _run("get_scene_tree", {"max_depth": "not a number"})
	assert_true(r.success)


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


func test_create_node_uninstantiable_type() -> void:
	# Object is the root non-Node class — exists but not a Node.
	var r := _run("create_node", {"type": "Object"})
	assert_false(r.success)


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
