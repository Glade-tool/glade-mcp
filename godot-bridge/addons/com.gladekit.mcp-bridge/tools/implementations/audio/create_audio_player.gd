extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates an audio player node and (optionally) assigns a stream in one call —
# the wiring step that turns an imported res://assets/audio/** file into
# something that actually plays. The asset pipeline can already download and
# import SFX / music (import_asset), but until now there was no tool to put a
# player in the scene, so imported audio dead-ended at "imported."
#
# Godot has THREE player classes and they do NOT share a base beyond Node:
#   AudioStreamPlayer    — non-positional. Plays at full volume everywhere.
#                          The right choice for music, ambience, and UI sounds.
#   AudioStreamPlayer2D  — positional in a 2D world (pans + attenuates by the
#                          listener/Camera2D distance).
#   AudioStreamPlayer3D  — positional in a 3D world (spatialized, distance
#                          attenuation, optional Doppler).
#
# Default is NON-positional (positional=false): a bare create_audio_player just
# plays a sound that's audible no matter where it sits, which is what "add
# background music" / "play this sound" almost always means. This deliberately
# differs from the dimension-aware default of create_camera / create_light: the
# non-positional player is dimension-agnostic and correct for music/UI, and
# silently attenuating background music by distance reads as broken. Pass
# positional=true for world SFX (a coin pickup, an enemy growl); the 2D vs 3D
# family is then inferred from the open scene's root (override with `space`).
#
# Args:
#   name:        String — node name. Default: the stream's filename (when a
#                stream is given) else the Godot class name.
#   parent_path: String — scene-relative parent. Default: scene root.
#   stream:      String — res:// path to an AudioStream (.ogg/.mp3/.wav) to
#                assign immediately. Validated: must exist and load as an
#                AudioStream. Omit to create an empty player.
#   positional:  bool — false (default) → AudioStreamPlayer; true → a positional
#                AudioStreamPlayer2D / AudioStreamPlayer3D.
#   space:       "2d" | "3d" — positional family. Inferred from the scene root
#                when omitted; only consulted when positional=true.
#   volume_db:   float — output volume in decibels (0 = unchanged, -80 = silent).
#                Default: 0.
#   autoplay:    bool — start playing when the scene loads. Default: false.
#   bus:         String — target audio bus. Default: "Master". A bus that does
#                not exist on the project's AudioServer is still applied but
#                flagged in `bus_warning` (Godot would route it to nothing).
#   pitch_scale: float — playback speed / pitch multiplier. Default: 1.
#   position:    "x,y" (2D) / "x,y,z" (3D) — initial position. Positional only.
#   max_distance: float — distance past which the sound is inaudible (positional
#                 only; 0 means "no limit" in Godot).
#
# Response payload:
#   node_path, type (actual Godot class), space ("2d"|"3d"|"none"),
#   positional (bool), stream (assigned res:// path or null), autoplay, bus,
#   bus_warning (only when the bus is unknown)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "create_audio_player"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open",
			["Call open_scene first", "Or create_scene to scaffold a new one"]
		)

	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return ToolUtils.error("Parent '%s' not found" % parent_path)

	# Resolve the stream first so a bad path fails before we add a node.
	var stream: AudioStream = null
	var stream_path: String = ToolUtils.parse_path_arg(args, "stream")
	if not stream_path.is_empty():
		if not FileAccess.file_exists(stream_path):
			return ToolUtils.error_with_solutions(
				"Audio stream does not exist at '%s'" % stream_path,
				[
					"Check the path with list_assets / list_imported_assets",
					"Import audio first with import_asset (assetType='audio_sfx' | 'audio_music')",
				]
			)
		var res = load(stream_path)
		if not (res is AudioStream):
			return ToolUtils.error_with_solutions(
				"Resource at '%s' is %s, not an AudioStream" % [stream_path, _class_of(res)],
				["Pass an imported .ogg / .mp3 / .wav", "Run list_imported_assets to see audio you've imported"]
			)
		stream = res

	var positional: bool = ToolUtils.parse_bool_arg(args, "positional", false)

	# Untyped on purpose: the three player classes share no base beyond Node
	# (AudioStreamPlayer → Node, AudioStreamPlayer2D → Node2D,
	# AudioStreamPlayer3D → Node3D), so a `Node`-typed var would reject the
	# shared property writes below at parse time. Dynamic access is safe — the
	# branch picks a concrete class that has every property we set.
	var player
	var space: String
	if not positional:
		player = AudioStreamPlayer.new()
		space = "none"
	else:
		# Positional → 2D / 3D family, inferred from the scene root like the
		# other dimension-aware creators.
		space = ToolUtils.resolve_space(args)
		if space != "2d" and space != "3d":
			return ToolUtils.error_with_solutions(
				"Unknown space '%s'" % space,
				["Use space='2d' for an AudioStreamPlayer2D", "Use space='3d' for an AudioStreamPlayer3D"]
			)
		player = AudioStreamPlayer2D.new() if space == "2d" else AudioStreamPlayer3D.new()

	# Name: prefer an explicit name, else derive from the stream filename
	# (matching create_sprite_2d), else fall back to the class name.
	var default_name: String = player.get_class()
	if not stream_path.is_empty():
		default_name = stream_path.get_file().get_basename()
	player.name = ToolUtils.parse_string_arg(args, "name", default_name)

	if stream != null:
		player.stream = stream

	player.volume_db = ToolUtils.parse_float_arg(args, "volume_db", 0.0)
	player.autoplay = ToolUtils.parse_bool_arg(args, "autoplay", false)
	player.pitch_scale = ToolUtils.parse_float_arg(args, "pitch_scale", 1.0)

	var bus: String = ToolUtils.parse_string_arg(args, "bus", "Master")
	player.bus = StringName(bus)
	var bus_warning: String = ""
	if AudioServer.get_bus_index(bus) == -1:
		bus_warning = "Bus '%s' does not exist on the project's AudioServer — playback would route to nothing. Known buses: %s" % [bus, _bus_names()]

	# Positional-only extras: placement + audible range.
	if positional:
		if space == "2d":
			player.position = ToolUtils.parse_vector2_arg(args, "position", Vector2.ZERO)
		else:
			player.position = ToolUtils.parse_vector3_arg(args, "position", Vector3.ZERO)
		if args.has("max_distance"):
			player.max_distance = ToolUtils.parse_float_arg(args, "max_distance", player.max_distance)

	parent.add_child(player)
	player.owner = root

	var payload: Dictionary = {
		"node_path": ToolUtils.node_relative_path(player),
		"type": player.get_class(),
		"space": space,
		"positional": positional,
		"stream": stream_path if not stream_path.is_empty() else null,
		"autoplay": player.autoplay,
		"bus": bus,
	}
	if not bus_warning.is_empty():
		payload["bus_warning"] = bus_warning

	return ToolUtils.success("Created %s '%s'" % [player.get_class(), player.name], payload)


func _bus_names() -> String:
	var names: PackedStringArray = []
	for i in AudioServer.bus_count:
		names.append(AudioServer.get_bus_name(i))
	return ", ".join(names)


func _class_of(v) -> String:
	if v is Object and v != null:
		return (v as Object).get_class()
	return "non-Resource"
