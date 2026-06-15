extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Mutates an existing audio player (AudioStreamPlayer / AudioStreamPlayer2D /
# AudioStreamPlayer3D). Sets only the properties the agent passes — omitted
# args leave existing values untouched, so "turn the music down" is one call
# without round-tripping the rest. This is the mutate counterpart to
# create_audio_player, mirroring set_light_properties for lights.
#
# The three player classes share no base beyond Node, so this checks all three
# explicitly. volume_db / autoplay / bus / pitch_scale apply to every player;
# max_distance is positional-only (AudioStreamPlayer2D / 3D). Wrong-class args
# land in `ignored_properties` with a reason and the call still succeeds for
# the args that DID apply — the same partial-success contract as
# set_light_properties / set_node_resource.
#
# To swap the actual audio clip, use set_node_resource(property="stream", ...).
#
# Args:
#   node_path:   String (required) — scene-relative path to an audio player.
#   volume_db:   float  — output volume in decibels (0 = unity, -80 = silent).
#   autoplay:    bool   — play automatically when the scene loads.
#   bus:         String — target audio bus. A bus missing from the project's
#                AudioServer is applied but flagged in `ignored_properties`
#                (it would route to nothing).
#   pitch_scale: float  — playback speed / pitch multiplier.
#   max_distance: float — audible range (AudioStreamPlayer2D / 3D only; 0 = no
#                limit). Ignored with a reason on a non-positional player.
#
# Response payload:
#   node_path, type, applied_properties: [String],
#   ignored_properties: [{name, reason}], current: {volume_db, autoplay, ...}

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "set_audio_player_properties"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	if not args.has("node_path"):
		return ToolUtils.error("node_path is required")
	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	var node: Node = ToolUtils.find_node_by_path(node_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found in edited scene" % node_path)

	var is_positional: bool = node is AudioStreamPlayer2D or node is AudioStreamPlayer3D
	if not (node is AudioStreamPlayer or is_positional):
		return ToolUtils.error_with_solutions(
			"Node '%s' is %s, not an audio player" % [node_path, node.get_class()],
			[
				"Use create_audio_player to add an AudioStreamPlayer / 2D / 3D first",
				"To assign the clip itself use set_node_resource(property='stream', ...)",
			]
		)

	# Untyped alias for property access: the three player classes share no base
	# beyond Node, so a `Node`-typed var would reject these property reads/writes
	# at parse time. The audio-player guard above guarantees the props exist.
	var player = node

	var applied: Array = []
	var ignored: Array = []

	# Shared across all three player classes.
	if args.has("volume_db"):
		player.volume_db = ToolUtils.parse_float_arg(args, "volume_db", player.volume_db)
		applied.append("volume_db")
	if args.has("autoplay"):
		player.autoplay = ToolUtils.parse_bool_arg(args, "autoplay", player.autoplay)
		applied.append("autoplay")
	if args.has("pitch_scale"):
		player.pitch_scale = ToolUtils.parse_float_arg(args, "pitch_scale", player.pitch_scale)
		applied.append("pitch_scale")
	if args.has("bus"):
		var bus: String = ToolUtils.parse_string_arg(args, "bus", String(player.bus))
		if AudioServer.get_bus_index(bus) == -1:
			ignored.append({"name": "bus", "reason": "bus '%s' does not exist on the AudioServer (known: %s)" % [bus, _bus_names()]})
		else:
			player.bus = StringName(bus)
			applied.append("bus")

	# Positional-only.
	if args.has("max_distance"):
		if is_positional:
			player.max_distance = ToolUtils.parse_float_arg(args, "max_distance", player.max_distance)
			applied.append("max_distance")
		else:
			ignored.append({"name": "max_distance", "reason": "%s is non-positional — only AudioStreamPlayer2D / 3D attenuate by distance" % node.get_class()})

	if applied.is_empty() and ignored.is_empty():
		return ToolUtils.error_with_solutions(
			"No audio properties were provided",
			[
				"Pass at least one of: volume_db, autoplay, bus, pitch_scale, max_distance",
				"To change the clip use set_node_resource(property='stream', ...)",
			]
		)

	var msg := "Updated %d audio propert%s on '%s'" % [applied.size(), "y" if applied.size() == 1 else "ies", node_path]
	return ToolUtils.success(msg, {
		"node_path": ToolUtils.node_relative_path(node),
		"type": node.get_class(),
		"applied_properties": applied,
		"ignored_properties": ignored,
		"current": _current_state(player, is_positional),
	})


# `player` is untyped — see the alias note in execute(): the audio player
# classes share no base that declares these properties.
func _current_state(player, is_positional: bool) -> Dictionary:
	var state: Dictionary = {
		"volume_db": player.volume_db,
		"autoplay": player.autoplay,
		"bus": String(player.bus),
		"pitch_scale": player.pitch_scale,
	}
	if is_positional:
		state["max_distance"] = player.max_distance
	return state


func _bus_names() -> String:
	var names: PackedStringArray = []
	for i in AudioServer.bus_count:
		names.append(AudioServer.get_bus_name(i))
	return ", ".join(names)
