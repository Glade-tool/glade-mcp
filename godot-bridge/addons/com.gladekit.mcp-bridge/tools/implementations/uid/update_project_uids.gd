extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Regenerates .uid sidecars across the project, fixing references that
# went stale after manual file moves outside the editor.
#
# Version-gated: Godot 4.4+. Adapted (with MIT attribution, see
# godot-bridge/NOTICE) from godot-mcp's resave_resources op at
# src/scripts/godot_operations.gd:889-1090. Their version pre-debugged
# the resave-after-uid-change flow (their issues #102, #104).
#
# The implementation triggers a full filesystem scan then resaves any
# resource that resolves to a UID. The editor picks up .uid sidecars
# created/updated as a side effect of the resave pass.
#
# Args:
#   subdir: String — limit the scan to res://<subdir>/ (default: full project)
#
# Response payload:
#   scanned:   int — number of resources visited
#   resaved:   int — number that were rewritten
#   skipped:   int — number that already had a valid UID and no rewrite was needed
#   subdir:    String — the path actually scanned

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "update_project_uids"
	requires_edit_mode = true
	min_godot_version = "4.4"


func execute(args: Dictionary) -> Dictionary:
	var subdir: String = ToolUtils.parse_string_arg(args, "subdir")
	var scan_root := "res://" if subdir.is_empty() else ("res://" + subdir.lstrip("/").rstrip("/"))

	# Trigger a full re-scan so the editor's filesystem view is current
	# before we walk it.
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.scan()

	var scanned := 0
	var resaved := 0
	var skipped := 0
	# Resource extensions that participate in the UID system. Other
	# files (.png, .gd, etc.) don't get sidecars at the resource level.
	var resource_exts: PackedStringArray = PackedStringArray(["tscn", "scn", "tres", "res", "material", "shader", "anim"])

	# Reflected access — see notes in get_uid.gd for why.
	if not ResourceLoader.has_method("get_resource_uid"):
		return ToolUtils.error("ResourceLoader.get_resource_uid unavailable (requires Godot 4.4+)")
	var invalid_id := -1  # ResourceUID.INVALID_ID is documented as -1

	var stack: Array = [scan_root]
	while not stack.is_empty():
		var dir_path: String = stack.pop_back()
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		dir.list_dir_begin()
		while true:
			var entry := dir.get_next()
			if entry.is_empty():
				break
			if entry.begins_with("."):
				continue
			var entry_path: String = dir_path.path_join(entry)
			if dir.current_is_dir():
				# Skip .godot/ and addons/ to avoid editor-managed files +
				# vendored third-party resources we shouldn't touch.
				if entry == ".godot" or entry == "addons":
					continue
				stack.push_back(entry_path)
				continue
			var ext := entry.get_extension().to_lower()
			if not resource_exts.has(ext):
				continue
			scanned += 1
			var current_uid: int = ResourceLoader.call("get_resource_uid", entry_path)
			if current_uid != invalid_id:
				skipped += 1
				continue
			# Load → save round-trip causes Godot to mint a UID if one is
			# missing. This is the same pattern godot-mcp uses.
			var res = load(entry_path)
			if res == null:
				continue
			var save_err := ResourceSaver.save(res, entry_path)
			if save_err == OK:
				resaved += 1
		dir.list_dir_end()

	# Final rescan so the editor picks up newly-created .uid files.
	if fs != null:
		fs.scan()

	return ToolUtils.success("UID resave pass complete", {
		"scanned": scanned,
		"resaved": resaved,
		"skipped": skipped,
		"subdir": scan_root,
	})
