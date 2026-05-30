extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Read existing signal connections involving a node — outgoing (signals the
# node emits and where each one is wired), incoming (signals from other
# nodes that target this node), or both. Read-only and safe in play mode.
#
# Use `response_format="detailed"` to additionally list every signal
# *declared* on the node (whether anything is connected or not) — useful
# when planning a new connection and the agent needs to see what's
# available.
#
# Use `signal_name` to narrow the result to a specific signal.
#
# Args:
#   node_path:       String (required) — scene-relative path.
#   signal_name:     String           — filter to this signal only.
#   direction:       String           — "out" | "in" | "both" (default "both")
#   response_format: String           — "concise" (default) | "detailed"
#
# Response payload (concise):
#   connections: [
#     {
#       signal,
#       direction,         "out" | "in"
#       other_node_path,   target_path for "out", emitter_path for "in"
#       method,            method called on the receiving side
#       persistent: bool,
#     }
#   ]
#   count: int
#
# Detailed adds:
#   available_signals: [
#     { name, args: [String], total_connected: int }
#   ]
#   This is the canonical "what can I connect to" reference for planning.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "list_signal_connections"
	requires_edit_mode = false  # read-only — safe during play


func execute(args: Dictionary) -> Dictionary:
	var missing := ToolUtils.require_string(args, "node_path")
	if not missing.is_empty():
		return ToolUtils.error(missing)

	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	var node: Node = ToolUtils.find_node_by_path(node_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found in the edited scene" % node_path)

	var signal_filter: String = ToolUtils.parse_string_arg(args, "signal_name")
	var direction: String = ToolUtils.parse_string_arg(args, "direction", "both").to_lower()
	if direction != "out" and direction != "in" and direction != "both":
		return ToolUtils.error("direction must be 'out' | 'in' | 'both' (got '%s')" % direction)
	var detailed: bool = ToolUtils.parse_string_arg(args, "response_format", "concise").to_lower() == "detailed"

	var connections: Array = []

	if direction == "out" or direction == "both":
		connections.append_array(_outgoing_for_node(node, signal_filter))

	if direction == "in" or direction == "both":
		# Incoming connections are stored on the EMITTER, not on the receiver,
		# so we have to scan the whole scene tree once per call.
		connections.append_array(_incoming_for_node(node, signal_filter))

	var payload: Dictionary = {
		"connections": connections,
		"count": connections.size(),
	}

	if detailed:
		payload["available_signals"] = _available_signals(node)

	return ToolUtils.success(
		"Found %d connection(s) for '%s' (direction=%s)" % [connections.size(), node_path, direction],
		payload,
	)


# ── Helpers ────────────────────────────────────────────────────────────────

func _outgoing_for_node(node: Node, signal_filter: String) -> Array:
	var out: Array = []
	for sig_entry in node.get_signal_list():
		var sig_name := String(sig_entry.get("name", ""))
		if not signal_filter.is_empty() and sig_name != signal_filter:
			continue
		for conn in node.get_signal_connection_list(sig_name):
			var callable: Callable = conn.get("callable", Callable())
			var target_object = callable.get_object()
			var target_path := ""
			if target_object is Node:
				target_path = ToolUtils.node_relative_path(target_object as Node)
				if target_path.is_empty():
					target_path = String((target_object as Node).name)
			out.append({
				"signal": sig_name,
				"direction": "out",
				"other_node_path": target_path,
				"method": callable.get_method(),
				"persistent": _flags_have_persist(int(conn.get("flags", 0))),
			})
	return out


func _incoming_for_node(node: Node, signal_filter: String) -> Array:
	var out: Array = []
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return out
	var stack: Array = [root]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		for child in current.get_children():
			stack.push_back(child)
		if current == node:
			continue  # outgoing is handled by _outgoing_for_node
		for sig_entry in current.get_signal_list():
			var sig_name := String(sig_entry.get("name", ""))
			if not signal_filter.is_empty() and sig_name != signal_filter:
				continue
			for conn in current.get_signal_connection_list(sig_name):
				var callable: Callable = conn.get("callable", Callable())
				if callable.get_object() != node:
					continue
				var emitter_path := ToolUtils.node_relative_path(current)
				if emitter_path.is_empty():
					emitter_path = String(current.name)
				out.append({
					"signal": sig_name,
					"direction": "in",
					"other_node_path": emitter_path,
					"method": callable.get_method(),
					"persistent": _flags_have_persist(int(conn.get("flags", 0))),
				})
	return out


# Detailed mode: every signal declared on the node, with its arg names and
# how many connections are currently wired to it. Helps the agent reason
# about availability ("is there a `body_entered`? is anything connected?").
func _available_signals(node: Node) -> Array:
	var out: Array = []
	for sig_entry in node.get_signal_list():
		var sig_name := String(sig_entry.get("name", ""))
		if sig_name.is_empty():
			continue
		var arg_names: Array = []
		var raw_args = sig_entry.get("args", [])
		if raw_args is Array:
			for a in raw_args:
				if a is Dictionary:
					arg_names.append(String(a.get("name", "")))
		out.append({
			"name": sig_name,
			"args": arg_names,
			"total_connected": node.get_signal_connection_list(sig_name).size(),
		})
	out.sort_custom(func(a, b): return String(a.name) < String(b.name))
	return out


func _flags_have_persist(bits: int) -> bool:
	# CONNECT_PERSIST = 2
	return (bits & 2) != 0
