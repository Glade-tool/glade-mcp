extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Remove a persistent signal connection (the kind saved with the .tscn).
# Inverse of connect_signal. All four identifying fields must match the
# connection exactly — call `list_signal_connections` if the agent is
# uncertain about the exact spelling.
#
# Refuses with a clear error if the connection doesn't exist; never silently
# no-ops, because a missed disconnect is the exact bug pattern we want to
# surface (agent thought it removed a handler, but it kept firing).
#
# Args (all required):
#   emitter_path: String
#   signal_name:  String
#   target_path:  String
#   method_name:  String
#
# Response payload:
#   removed: {emitter_path, signal_name, target_path, method_name}

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "disconnect_signal"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	for required in ["emitter_path", "signal_name", "target_path", "method_name"]:
		var missing := ToolUtils.require_string(args, required)
		if not missing.is_empty():
			return ToolUtils.error(missing)

	var emitter_path: String = ToolUtils.parse_string_arg(args, "emitter_path")
	var signal_name: String = ToolUtils.parse_string_arg(args, "signal_name")
	var target_path: String = ToolUtils.parse_string_arg(args, "target_path")
	var method_name: String = ToolUtils.parse_string_arg(args, "method_name")

	var emitter: Node = ToolUtils.find_node_by_path(emitter_path)
	if emitter == null:
		return ToolUtils.error("Emitter '%s' not found in the edited scene" % emitter_path)
	var target: Node = ToolUtils.find_node_by_path(target_path)
	if target == null:
		return ToolUtils.error("Target '%s' not found in the edited scene" % target_path)

	var callable := Callable(target, method_name)
	if not emitter.is_connected(signal_name, callable):
		return ToolUtils.error(
			"No connection found: %s.%s -> %s.%s. List the actual wiring with list_signal_connections." % [
				emitter_path, signal_name, target_path, method_name,
			]
		)

	emitter.disconnect(signal_name, callable)
	return ToolUtils.success(
		"Disconnected %s.%s -> %s.%s" % [emitter_path, signal_name, target_path, method_name],
		{
			"removed": {
				"emitter_path": emitter_path,
				"signal_name": signal_name,
				"target_path": target_path,
				"method_name": method_name,
			},
		},
	)
