extends GutTest

# Integration tests for the uid/ category. ResourceUID is a Godot 4.4+ API,
# so these tests skip themselves on older engines (the bridge already
# version-gates dispatch via tool_instance.min_godot_version; this test
# mirrors the gate so it runs on every CI matrix entry without spurious
# failures on 4.3).
#
# Test layout:
#   - Stage a throwaway resource at user:// (NOT res://) so we don't touch
#     the project tree and don't trip DemoAssetsGuard.
#   - get_uid: assert it returns either a uid:// string or has_uid=false
#     (depending on whether the editor has minted one yet for our staged file).
#   - update_project_uids: scope to a synthetic subdir we control so the
#     scan is fast and deterministic.

const Registry = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd")
const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const STAGE_DIR_RES := "res://_gladekit_uid_test/"
const STAGE_FILE := "res://_gladekit_uid_test/sample.tres"

var _registry = null


func should_skip_script():
	# UID tools call EditorInterface.get_resource_filesystem to register the
	# minted .uid sidecar files. See test_signal_tools.gd::should_skip_script
	# for why integration tests skip under GUT play_custom_scene.
	if ToolUtils.get_edited_scene_root_safe() == null:
		return "requires editor context (skipped under GUT play_custom_scene; verify by driving the bridge through an MCP client with the editor open)"
	# Engine version gate — UID tools require Godot 4.4+. Skip the whole
	# file on older engines rather than letting individual tests fall through
	# to the dispatcher's version-refusal error path.
	var info := Engine.get_version_info()
	if int(info.get("major", 0)) < 4 or (int(info.get("major", 0)) == 4 and int(info.get("minor", 0)) < 4):
		return "Godot 4.4+ required for ResourceUID tools (running %s)" % info.get("string", "")
	return false


func before_each() -> void:
	_registry = Registry.new()

	# Stage a throwaway resource we can probe for a UID. Use a Resource
	# (not a Script or scene) because Godot mints UIDs for any tres/res
	# resource on save.
	var abs_dir := ProjectSettings.globalize_path(STAGE_DIR_RES)
	DirAccess.make_dir_recursive_absolute(abs_dir)
	# Named stub_resource (not `stub`) — GutTest defines a `stub()` method,
	# and a local var with the same name shadows it and emits a warning.
	var stub_resource := Resource.new()
	ResourceSaver.save(stub_resource, STAGE_FILE)
	# Force the editor to scan so its UID cache picks up the file before
	# get_uid queries it. Best-effort — the test below tolerates either
	# has_uid=true or has_uid=false.
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(STAGE_FILE)


func after_each() -> void:
	# Clean the staged file + dir. Best-effort; a failure here only leaks
	# a kilobyte and won't break subsequent runs. (Engine + editor gates
	# are handled by should_skip_script, so reaching this means setup ran.)
	if FileAccess.file_exists(STAGE_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(STAGE_FILE))
	var sidecar := STAGE_FILE + ".uid"
	if FileAccess.file_exists(sidecar):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sidecar))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(STAGE_DIR_RES))
	_registry = null


func _run(tool_name: String, args: Dictionary) -> Dictionary:
	var t = _registry.get_tool(tool_name)
	assert_not_null(t, "Tool '%s' must be registered" % tool_name)
	return t.execute(args)


# ── get_uid ──────────────────────────────────────────────────────────────

func test_get_uid_for_staged_resource() -> void:
	var r := _run("get_uid", {"path": STAGE_FILE})
	assert_true(r.success, "get_uid should succeed on a saved resource: %s" % r.get("message", ""))
	# Either Godot has minted a UID (has_uid=true with non-empty "uid://...")
	# or it hasn't yet (has_uid=false with empty uid). Both are valid states
	# right after save; the tool's contract is "return whichever state is
	# current, never raise."
	assert_true(r.has("has_uid"))
	if bool(r.has_uid):
		assert_true(String(r.uid).begins_with("uid://"), "uid string should be in uid:// form")


func test_get_uid_missing_path_errors() -> void:
	var r := _run("get_uid", {})
	assert_false(r.success, "get_uid with no path should fail")


func test_get_uid_nonexistent_file_errors() -> void:
	var r := _run("get_uid", {"path": "res://does/not/exist.tres"})
	assert_false(r.success, "get_uid on missing file should fail")


# ── update_project_uids ──────────────────────────────────────────────────

func test_update_project_uids_scoped_to_subdir() -> void:
	# Scope the scan to our staged subdir so the test stays fast on large
	# projects and doesn't sweep the user's whole tree.
	var r := _run("update_project_uids", {"subdir": "_gladekit_uid_test"})
	assert_true(r.success, "update_project_uids should succeed: %s" % r.get("message", ""))
	assert_true(r.has("scanned"))
	assert_true(r.has("resaved"))
	assert_true(r.has("skipped"))
	# At minimum the staged sample.tres should have been visited.
	assert_gt(int(r.scanned), 0, "scoped scan should have seen at least one resource")


func test_update_project_uids_empty_subdir() -> void:
	# A bogus subdir should scan nothing — but should NOT error (the tool
	# treats "empty directory" as a successful no-op).
	var r := _run("update_project_uids", {"subdir": "_does_not_exist_anywhere"})
	assert_true(r.success, "bogus subdir should succeed (scanned=0)")
	assert_eq(int(r.scanned), 0)
