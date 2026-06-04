extends RefCounted

# Gathers project + editor context for an MCP client to embed in a system
# prompt prefix. Read-only — never mutates state. Mirrors the Unity bridge's
# UnityContextGatherer service.
#
# The returned dictionary is JSON-serializable and small enough to embed
# in a system prompt prefix.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


static func gather() -> Dictionary:
	return {
		"engine": "godot",
		"engine_version": _engine_version(),
		"project": _project_info(),
		"edited_scene": _edited_scene_info(),
		"selection": _selection_paths(),
		"enabled_addons": _enabled_addons(),
	}


static func _engine_version() -> String:
	var v := Engine.get_version_info()
	return str(v.get("major", 0)) + "." + str(v.get("minor", 0)) + "." + str(v.get("patch", 0))


static func _project_info() -> Dictionary:
	var info: Dictionary = {
		"name": str(ProjectSettings.get_setting("application/config/name", "")),
		"main_scene": str(ProjectSettings.get_setting("application/run/main_scene", "")),
	}
	# Renderer info matters for shader/material decisions (Compatibility
	# vs Forward+ has very different StandardMaterial3D behavior).
	info["renderer"] = str(ProjectSettings.get_setting("rendering/renderer/rendering_method", ""))
	return info


static func _edited_scene_info() -> Dictionary:
	# Safe wrapper — see ToolUtils.get_edited_scene_root_safe. EditorInterface
	# is unreachable from non-editor contexts (test runner, etc.); the safe
	# helper returns null there, which is the same path as "no scene open."
	var root := ToolUtils.get_edited_scene_root_safe()
	if root == null:
		return {"open": false}
	return {
		"open": true,
		"scene_path": root.scene_file_path,
		"root_name": String(root.name),
		"root_type": root.get_class(),
		"node_count": _count_nodes(root),
	}


static func _count_nodes(node: Node) -> int:
	var total := 1
	for c in node.get_children():
		total += _count_nodes(c)
	return total


static func _selection_paths() -> Array:
	# Same singleton-via-Engine pattern as ToolUtils.get_edited_scene_root_safe.
	# Bare `EditorInterface.<method>` parses as a static call on the class,
	# which doesn't have the method outside editor context. Fetching the
	# singleton via Engine routes the call through the actual instance.
	var ei: Object = Engine.get_singleton("EditorInterface") if Engine.has_singleton("EditorInterface") else null
	if ei == null:
		return []
	var selection := ei.get_selection()
	if selection == null:
		return []
	var nodes := selection.get_selected_nodes()
	var paths: Array = []
	for n in nodes:
		var rel := ToolUtils.node_relative_path(n)
		paths.append(rel if not rel.is_empty() else String(n.name))
	return paths


static func _enabled_addons() -> Array:
	var enabled = ProjectSettings.get_setting("editor_plugins/enabled", PackedStringArray())
	# Setting is stored as PackedStringArray of plugin.cfg paths.
	var out: Array = []
	for entry in enabled:
		out.append(str(entry))
	return out
