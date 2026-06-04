extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Wires a signal from an emitter node to a method on a target node, persisted
# with the scene .tscn (CONNECT_PERSIST). The connection survives scene
# reloads and ships with the game — same as wiring a connection through the
# Godot editor's Node panel.
#
# Refuses to wire to a method that doesn't exist on the target (Godot's
# runtime would silently no-op, which is the classic "I connected it but
# nothing happens" bug). Refuses to wire a signal the emitter doesn't
# declare. Both refusals come back with `possible_solutions` listing the
# closest matches so the agent can self-correct.
#
# For runtime-only wiring (created/destroyed during gameplay), the agent
# should write GDScript using `signal.connect(...)` — that's not what this
# tool is for.
#
# Args:
#   emitter_path: String (required) — scene-relative NodePath of the emitter.
#   signal_name:  String (required) — name of the signal declared on emitter.
#   target_path:  String (required) — scene-relative NodePath of the receiver.
#   method_name:  String (required) — name of the method on target to call.
#   flags:        Array[String]      — subset of ["deferred", "one_shot"]. The
#                                      PERSIST flag is always set on top.
#
# Response payload:
#   connection: {emitter_path, signal_name, target_path, method_name, flags,
#                already_connected: bool}

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "connect_signal"
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

	if not _signal_exists(emitter, signal_name):
		var available := _signal_names(emitter)
		return ToolUtils.error_with_solutions(
			"Signal '%s' is not declared on %s ('%s')" % [signal_name, emitter.get_class(), emitter_path],
			_closest(signal_name, available),
			{"available_signals": available},
		)

	if not target.has_method(method_name):
		var available_methods := _public_methods(target)
		return ToolUtils.error_with_solutions(
			"Method '%s' is not defined on the script attached to '%s' (%s). Attach a script that declares it, or pick an existing method." % [method_name, target_path, target.get_class()],
			_closest(method_name, available_methods),
			{},
		)

	var flag_bits := _parse_flags(args)
	# CONNECT_PERSIST is always set — that's the entire point of this tool
	# (editor-time, scene-persistent wiring). PERSIST = 2 in Godot 4.x.
	flag_bits |= 2

	var callable := Callable(target, method_name)
	if emitter.is_connected(signal_name, callable):
		return ToolUtils.success(
			"Already connected: %s.%s -> %s.%s" % [emitter_path, signal_name, target_path, method_name],
			{
				"connection": {
					"emitter_path": emitter_path,
					"signal_name": signal_name,
					"target_path": target_path,
					"method_name": method_name,
					"flags": _flag_bits_to_names(flag_bits),
					"already_connected": true,
				},
			},
		)

	var err := emitter.connect(signal_name, callable, flag_bits)
	if err != OK:
		return ToolUtils.error("Godot's Node.connect() refused the connection (error %d)" % err)

	return ToolUtils.success(
		"Connected %s.%s -> %s.%s" % [emitter_path, signal_name, target_path, method_name],
		{
			"connection": {
				"emitter_path": emitter_path,
				"signal_name": signal_name,
				"target_path": target_path,
				"method_name": method_name,
				"flags": _flag_bits_to_names(flag_bits),
				"already_connected": false,
			},
		},
	)


# ── Helpers ────────────────────────────────────────────────────────────────

func _signal_exists(node: Node, signal_name: String) -> bool:
	for entry in node.get_signal_list():
		if String(entry.get("name", "")) == signal_name:
			return true
	return false


func _signal_names(node: Node) -> Array:
	var out: Array = []
	for entry in node.get_signal_list():
		var n := String(entry.get("name", ""))
		if not n.is_empty():
			out.append(n)
	out.sort()
	return out


# Returns public-looking method names from the node's script (and built-ins
# the user is likely to wire — _on_*_* handlers). Excludes Godot internals
# like `_ready`, `_process` since those aren't sensible callback targets.
func _public_methods(node: Node) -> Array:
	var out: Array = []
	for entry in node.get_method_list():
		var n := String(entry.get("name", ""))
		if n.is_empty():
			continue
		# Skip engine virtuals and private dunders unless they look like
		# signal-handler conventions (_on_*).
		if n.begins_with("_") and not n.begins_with("_on_"):
			continue
		out.append(n)
	out.sort()
	return out


func _parse_flags(args: Dictionary) -> int:
	var bits: int = 0
	if not args.has("flags"):
		return bits
	var raw = args["flags"]
	if raw == null:
		return bits
	# Accept a single string for ergonomics: flags="deferred"
	var list: Array = []
	if raw is String:
		list = [raw]
	elif raw is Array:
		list = raw
	else:
		return bits
	for f in list:
		match String(f).to_lower():
			"deferred":
				bits |= 1  # CONNECT_DEFERRED
			"one_shot", "oneshot":
				bits |= 4  # CONNECT_ONE_SHOT
			# CONNECT_PERSIST is forced on regardless; "persist" is a no-op
			# rather than an error so the agent can be defensive.
			"persist":
				bits |= 2
	return bits


func _flag_bits_to_names(bits: int) -> Array:
	var out: Array = []
	if bits & 1:
		out.append("deferred")
	if bits & 2:
		out.append("persist")
	if bits & 4:
		out.append("one_shot")
	return out


# Return up to 3 closest matches. Combines prefix/substring boosts (for
# partial input — agent typed "find_no" wanting "find_nodes") with
# Levenshtein edit distance (for typos — agent typed "timeput" wanting
# "timeout"). The old substring-only version missed the typo case
# entirely, which is by far the most common agent failure mode.
func _closest(target: String, candidates: Array) -> Array:
	var t := target.to_lower()
	if t.is_empty() or candidates.is_empty():
		return _alphabetical_fallback(candidates)
	var scored: Array = []
	for c in candidates:
		var cs := String(c).to_lower()
		var score := _similarity(t, cs)
		# 0.4 threshold: roughly "less than 60% of characters disagree".
		# Anything below this is probably noise, not a misspelling.
		if score >= 0.4:
			scored.append({"name": String(c), "score": score})
	if scored.is_empty():
		return _alphabetical_fallback(candidates)
	scored.sort_custom(func(a, b): return a.score > b.score)
	# When the top match is clearly excellent (>0.85), drop weak runners-up
	# (>0.2 below top). Otherwise the agent sees noise alongside the
	# obvious answer — e.g. typo "request_redy" should suggest only
	# "request_ready", not "request_ready, get_rid, queue_free".
	var top_score: float = scored[0].score
	var cutoff: float = top_score - 0.2 if top_score > 0.85 else 0.0
	var out: Array = []
	for i in min(3, scored.size()):
		if scored[i].score < cutoff:
			break
		out.append("Try '%s'" % scored[i].name)
	return out


# Fallback when nothing scores above the similarity threshold: show the
# first 3 alphabetical candidates so the agent at least sees the namespace.
func _alphabetical_fallback(candidates: Array) -> Array:
	var out: Array = []
	if candidates.is_empty():
		return out
	var sample: Array = candidates.duplicate()
	sample.sort()
	for i in min(3, sample.size()):
		out.append("Available: '%s'" % sample[i])
	return out


# Similarity score in [0, 1]. 1.0 = exact match.
# Prefix/substring overlap is treated as a strong signal even when the
# strings differ in length (so partial input scores high). Otherwise falls
# back to Levenshtein normalized by the longer string.
func _similarity(a: String, b: String) -> float:
	if a == b:
		return 1.0
	if a.is_empty() or b.is_empty():
		return 0.0
	if a.begins_with(b) or b.begins_with(a):
		return 0.85
	if a.contains(b) or b.contains(a):
		return 0.7
	var ed := ToolUtils.levenshtein(a, b)
	var max_len: int = max(a.length(), b.length())
	return 1.0 - float(ed) / float(max_len)
