extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Adds and configures a NavigationAgent3D as a child of a 3D body so that body
# can path across a baked NavigationRegion3D (see bake_navigation_mesh). This is
# the pathfinding primitive: the agent computes the route, but it does NOT move
# the body on its own — a movement script must read get_next_path_position()
# each physics frame and drive the body. The response ships a copy-pasteable
# movement loop, and create_enemy_3d is the vetted chaser if you want movement
# scaffolded for you.
#
# 3D-only (NavigationAgent3D). Pointed at a 2D node it refuses with a hint,
# matching the dimension guard on the rest of the 3D navigation family.
#
# Args:
#   node_path:               String (required) — scene-relative path to the
#                            Node3D (typically a CharacterBody3D) that should
#                            navigate. The agent is added as its child.
#   name:                    String — agent node name. Default "NavigationAgent3D".
#   path_desired_distance:   float — how close to a path point counts as reaching
#                            it. Default 0.5.
#   target_desired_distance: float — how close to the target counts as arrived
#                            (is_navigation_finished() flips true). Default 0.5.
#   radius:                  float — agent radius for avoidance. Default 0.5.
#   height:                  float — agent height for avoidance. Default 1.5.
#   max_speed:               float — max speed used by avoidance. Default 5.0.
#   avoidance_enabled:       bool — enable RVO local avoidance between agents.
#                            Default false (only needed with multiple agents).
#   target_position:         "x,y,z" — optional initial target the agent paths to.
#
# Response payload:
#   agent_path, parent_path, parent_type, avoidance_enabled, usage (a GDScript
#   movement-loop snippet — the agent is inert without it)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "add_navigation_agent"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open",
			["Call open_scene first", "Or create_scene to scaffold a new one"]
		)

	if not args.has("node_path"):
		return ToolUtils.error("node_path is required — the body that should navigate")
	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	var body: Node = ToolUtils.find_node_by_path(node_path)
	if body == null:
		return ToolUtils.error("Node '%s' not found in edited scene" % node_path)
	if not (body is Node3D):
		return ToolUtils.error_with_solutions(
			"Node '%s' is %s, not a Node3D — NavigationAgent3D needs a 3D parent" % [node_path, body.get_class()],
			[
				"Point node_path at a CharacterBody3D / Node3D",
				"2D navigation (NavigationAgent2D) is not yet supported by this tool",
			]
		)

	var agent := NavigationAgent3D.new()
	agent.name = ToolUtils.parse_string_arg(args, "name", "NavigationAgent3D")
	agent.path_desired_distance = ToolUtils.parse_float_arg(args, "path_desired_distance", 0.5)
	agent.target_desired_distance = ToolUtils.parse_float_arg(args, "target_desired_distance", 0.5)
	agent.radius = ToolUtils.parse_float_arg(args, "radius", 0.5)
	agent.height = ToolUtils.parse_float_arg(args, "height", 1.5)
	agent.max_speed = ToolUtils.parse_float_arg(args, "max_speed", 5.0)
	agent.avoidance_enabled = ToolUtils.parse_bool_arg(args, "avoidance_enabled", false)

	body.add_child(agent)
	agent.owner = root

	if args.has("target_position"):
		agent.target_position = ToolUtils.parse_vector3_arg(args, "target_position", Vector3.ZERO)

	return ToolUtils.success("Added NavigationAgent3D '%s' under '%s'" % [agent.name, node_path], {
		"agent_path": ToolUtils.node_relative_path(agent),
		"parent_path": ToolUtils.node_relative_path(body),
		"parent_type": body.get_class(),
		"avoidance_enabled": agent.avoidance_enabled,
		"usage": _USAGE_SNIPPET,
	})


# The canonical CharacterBody3D nav-follow loop. Without movement code the agent
# only computes paths — it never moves the body. Hand this to the model so it
# wires movement correctly (set target_position, gate on is_navigation_finished,
# step toward get_next_path_position) instead of re-deriving it and dropping the
# gravity / finished-check details.
const _USAGE_SNIPPET := """# On the CharacterBody3D that owns this NavigationAgent3D:
@export var speed := 5.0
@onready var _agent: NavigationAgent3D = $NavigationAgent3D

func set_destination(world_pos: Vector3) -> void:
	_agent.target_position = world_pos

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta
	if not _agent.is_navigation_finished():
		var next := _agent.get_next_path_position()
		var dir := (next - global_position).normalized()
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
	move_and_slide()
"""
