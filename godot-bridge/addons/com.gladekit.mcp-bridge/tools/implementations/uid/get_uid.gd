extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Reads the ResourceUID assigned to a resource path. Godot 4.4+ tracks
# resources by stable UID (the `.uid` sidecar files) so renames and moves
# don't break references — but the lookup API is non-obvious. This tool
# wraps it.
#
# Read-only. Version-gated: requires Godot 4.4+.
#
# Adapted (with MIT attribution, see godot-bridge/NOTICE) from godot-mcp's
# get_uid op at src/scripts/godot_operations.gd:889+. Their version
# already debugged several 4.4 edge cases — we mirror the safe path.
#
# Implementation note: the 4.4-only APIs (ResourceLoader.get_resource_uid,
# ResourceUID.INVALID_ID, ResourceUID.id_to_text) are accessed via
# reflection so this script parses cleanly on Godot 4.3 too. The bridge's
# min_godot_version gate stops dispatch before we ever call them on 4.3.
#
# Args:
#   path: String (required) — res:// path to the resource.
#
# Response payload:
#   path:     String
#   uid:      String — "uid://xxxxxxxxxx" form
#   uid_int:  int    — the underlying integer
#   has_uid:  bool   — false if Godot has not assigned one (yet)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "get_uid"
	requires_edit_mode = false
	min_godot_version = "4.4"


func execute(args: Dictionary) -> Dictionary:
	var path: String = ToolUtils.parse_path_arg(args, "path")
	if path.is_empty():
		return ToolUtils.error("path is required")
	if not FileAccess.file_exists(path):
		return ToolUtils.error("File does not exist at '%s'" % path)

	# Reflected access to the 4.4 APIs — keeps this file parseable on 4.3.
	if not ResourceLoader.has_method("get_resource_uid"):
		return ToolUtils.error("ResourceLoader.get_resource_uid unavailable on this Godot version (requires 4.4+)")
	var uid_int: int = ResourceLoader.call("get_resource_uid", path)
	var invalid_id := _invalid_uid_id()
	if uid_int == invalid_id:
		return ToolUtils.success("No UID assigned to '%s' yet" % path, {
			"path": path,
			"uid": "",
			"uid_int": uid_int,
			"has_uid": false,
		})
	var uid_str: String = _uid_to_text(uid_int)
	return ToolUtils.success("UID for '%s'" % path, {
		"path": path,
		"uid": uid_str,
		"uid_int": uid_int,
		"has_uid": true,
	})


func _invalid_uid_id() -> int:
	# ResourceUID.INVALID_ID is the canonical sentinel; the constant
	# resolves to -1 on every version that ships ResourceUID.
	var ru := ClassDB.instantiate("ResourceUID")
	if ru == null:
		return -1
	# `ResourceUID` is a singleton; instantiate may return null on some
	# builds. Fall back to the documented constant value.
	return -1


func _uid_to_text(uid_int: int) -> String:
	# Singleton call via the bound name. Works since Godot 4.0 added
	# ResourceUID; only the file-existence side is 4.4-new.
	return ResourceUID.id_to_text(uid_int)
