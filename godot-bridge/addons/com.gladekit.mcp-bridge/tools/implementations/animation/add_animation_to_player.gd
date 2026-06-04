extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Registers an Animation resource (saved as a .tres) with an AnimationPlayer
# so the player can later play it by name. AnimationPlayer in Godot 4
# organizes animations into named libraries; the default library is the empty
# string "" — when the agent calls play("jump"), the player resolves it as
# play("/jump") against the default library.
#
# If the requested library doesn't exist on the player yet, this tool creates
# it. That's the conventional single-library setup; multi-library splits are
# typically used for character variants (player_library, enemy_library, etc.).
#
# Workflow:
#   1. create_node(type="AnimationPlayer", parent_path="Player") — adds the player.
#   2. create_resource(type="Animation", path="res://anim/jump.tres") — empty Animation.
#   3. add_animation_to_player(...) — registers the .tres under a name.
#   4. add_animation_track + add_animation_keyframe — author the animation.
#   5. set_animation_properties — length + loop_mode.
#
# Persistence: the player's libraries dict is serialized into the scene
# (.tscn), so the change persists only after the scene is saved. The
# AnimationLibrary holds a *reference* to the Animation .tres, so editing
# the .tres later via add_animation_track / add_animation_keyframe doesn't
# require re-registering.
#
# Args:
#   player_path:    String (required) — scene-relative NodePath of an
#                                       AnimationPlayer node.
#   animation_path: String (required) — res:// path to an Animation .tres.
#   animation_name: String (required) — key the agent will play() by.
#   library_name:   String            — animation library name. Default ""
#                                       (the conventional default library).
#
# Response payload:
#   player_path, animation_name, library_name, library_created (bool — true
#   if the library didn't exist before this call), library_animation_count.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "add_animation_to_player"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	for required in ["player_path", "animation_path", "animation_name"]:
		var missing := ToolUtils.require_string(args, required)
		if not missing.is_empty():
			return ToolUtils.error(missing)

	var player_path: String = ToolUtils.parse_string_arg(args, "player_path")
	var animation_path: String = ToolUtils.parse_path_arg(args, "animation_path")
	var animation_name: String = ToolUtils.parse_string_arg(args, "animation_name")
	var library_name: String = ToolUtils.parse_string_arg(args, "library_name", "")

	var node: Node = ToolUtils.find_node_by_path(player_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found in the edited scene" % player_path)
	if not (node is AnimationPlayer):
		return ToolUtils.error_with_solutions(
			"Node '%s' is %s, not AnimationPlayer" % [player_path, node.get_class()],
			[
				"Create an AnimationPlayer first: create_node(type='AnimationPlayer', parent_path='...')",
				"Or pass a different player_path",
			]
		)
	var player: AnimationPlayer = node

	if not FileAccess.file_exists(animation_path):
		return ToolUtils.error_with_solutions(
			"Animation file not found at '%s'" % animation_path,
			[
				"Create the .tres first via create_resource(path='%s', type='Animation')" % animation_path,
				"Or check the path spelling — must begin with res://",
			]
		)

	var anim = ResourceLoader.load(animation_path)
	if anim == null:
		return ToolUtils.error("Failed to load resource at '%s'" % animation_path)
	if not (anim is Animation):
		return ToolUtils.error(
			"Resource at '%s' is %s, not Animation — create with type='Animation' via create_resource"
			% [animation_path, anim.get_class()]
		)

	var library_created := false
	var library: AnimationLibrary
	if player.has_animation_library(library_name):
		library = player.get_animation_library(library_name)
	else:
		library = AnimationLibrary.new()
		var add_err := player.add_animation_library(library_name, library)
		if add_err != OK:
			return ToolUtils.error("Failed to add animation library '%s' to player (err %d)" % [library_name, add_err])
		library_created = true

	if library.has_animation(animation_name):
		return ToolUtils.error_with_solutions(
			"Animation '%s' is already registered in library '%s' on '%s'" % [animation_name, library_name, player_path],
			[
				"Pick a different animation_name",
				"Or remove the existing entry in the editor first",
			]
		)

	var anim_err := library.add_animation(animation_name, anim)
	if anim_err != OK:
		return ToolUtils.error("library.add_animation('%s') failed (err %d)" % [animation_name, anim_err])

	return ToolUtils.success(
		"Added '%s' to AnimationPlayer '%s' (library '%s')%s" % [
			animation_name, player_path, library_name,
			" — save the scene to persist" if library_created else "",
		],
		{
			"player_path": player_path,
			"animation_name": animation_name,
			"library_name": library_name,
			"library_created": library_created,
			"library_animation_count": library.get_animation_list().size(),
		}
	)
