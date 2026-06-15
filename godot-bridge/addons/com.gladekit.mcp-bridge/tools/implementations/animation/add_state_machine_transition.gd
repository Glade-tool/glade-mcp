extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Connects two states in an AnimationTree's state machine with a transition.
# A transition defines HOW and WHEN the machine moves from one state to
# another — the cross-fade time, whether the switch waits for the current clip
# to finish, and (optionally) a condition that lets the machine advance on its
# own.
#
# Both endpoints must already exist as states (created via create_animation_tree
# with seed_states, or add_state_machine_state) — with two reserved exceptions:
#   "Start"  as `from_state` — the machine's entry point. A Start → X transition
#            makes X the state the machine begins in.
#   "End"    as `to_state`   — a terminal sink (rarely needed for looping
#            character setups).
#
# Driving transitions at runtime, two ways:
#   1. Explicit travel:   $AnimationTree["parameters/playback"].travel("run")
#      Works with any switch_mode; advance settings are ignored.
#   2. Auto-advance:      set advance_mode="auto" + an advance_condition; the
#      machine crosses on its own when the named condition parameter is true:
#      $AnimationTree["parameters/conditions/is_running"] = true
#
# Args:
#   tree_path:         String (required) — NodePath of the AnimationTree.
#   from_state:        String (required) — source state, or "Start".
#   to_state:          String (required) — destination state, or "End".
#   switch_mode:       "immediate" | "sync" | "at_end" — when the switch happens.
#                      immediate (default): cut now, cross-fading over xfade_time.
#                      sync: start the new clip at the old clip's playback ratio.
#                      at_end: wait for the current clip to finish first.
#   xfade_time:        float — cross-fade duration in seconds. Default 0.
#   advance_mode:      "disabled" | "enabled" | "auto" — Default "enabled".
#                      enabled: reachable via travel(). auto: also crosses by
#                      itself when advance_condition is true. disabled: off.
#   advance_condition: String — name of a bool condition parameter that gates an
#                      auto/enabled advance. Exposed at
#                      parameters/conditions/<name>. Optional.
#
# Response payload:
#   tree_path, from_state, to_state, switch_mode, xfade_time, advance_mode,
#   advance_condition, transition_count.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SMUtils = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/animation/state_machine_utils.gd")

const SWITCH_MODES := {
	"immediate": AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE,
	"sync": AnimationNodeStateMachineTransition.SWITCH_MODE_SYNC,
	"at_end": AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END,
}

const ADVANCE_MODES := {
	"disabled": AnimationNodeStateMachineTransition.ADVANCE_MODE_DISABLED,
	"enabled": AnimationNodeStateMachineTransition.ADVANCE_MODE_ENABLED,
	"auto": AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO,
}


func _init() -> void:
	tool_name = "add_state_machine_transition"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	for required in ["tree_path", "from_state", "to_state"]:
		var missing := ToolUtils.require_string(args, required)
		if not missing.is_empty():
			return ToolUtils.error(missing)

	var tree_path: String = ToolUtils.parse_string_arg(args, "tree_path")
	var resolved := SMUtils.resolve_state_machine(tree_path)
	if resolved.has("error"):
		return resolved["error"]
	var sm: AnimationNodeStateMachine = resolved["state_machine"]

	var from_state: String = ToolUtils.parse_string_arg(args, "from_state")
	var to_state: String = ToolUtils.parse_string_arg(args, "to_state")

	# "Start" is only valid as a source, "End" only as a destination.
	var from_err := _validate_endpoint(sm, from_state, true)
	if not from_err.is_empty():
		return ToolUtils.error_with_solutions(from_err, _state_hints(sm))
	var to_err := _validate_endpoint(sm, to_state, false)
	if not to_err.is_empty():
		return ToolUtils.error_with_solutions(to_err, _state_hints(sm))

	if from_state == to_state:
		return ToolUtils.error("A transition's from_state and to_state can't be the same ('%s')" % from_state)

	if sm.has_transition(StringName(from_state), StringName(to_state)):
		return ToolUtils.error_with_solutions(
			"A transition '%s' → '%s' already exists" % [from_state, to_state],
			["Each state pair can have one transition — remove it in the editor to re-add"]
		)

	var switch_mode_arg: String = ToolUtils.parse_string_arg(args, "switch_mode", "immediate").to_lower().strip_edges()
	if not SWITCH_MODES.has(switch_mode_arg):
		return ToolUtils.error_with_solutions(
			"Unknown switch_mode '%s'" % switch_mode_arg,
			["Use one of: %s" % ", ".join(SWITCH_MODES.keys())]
		)
	var advance_mode_arg: String = ToolUtils.parse_string_arg(args, "advance_mode", "enabled").to_lower().strip_edges()
	if not ADVANCE_MODES.has(advance_mode_arg):
		return ToolUtils.error_with_solutions(
			"Unknown advance_mode '%s'" % advance_mode_arg,
			["Use one of: %s" % ", ".join(ADVANCE_MODES.keys())]
		)

	var transition := AnimationNodeStateMachineTransition.new()
	transition.switch_mode = SWITCH_MODES[switch_mode_arg]
	transition.xfade_time = ToolUtils.parse_float_arg(args, "xfade_time", 0.0)
	transition.advance_mode = ADVANCE_MODES[advance_mode_arg]
	var advance_condition: String = ToolUtils.parse_string_arg(args, "advance_condition", "")
	if not advance_condition.is_empty():
		transition.advance_condition = StringName(advance_condition)

	sm.add_transition(StringName(from_state), StringName(to_state), transition)

	return ToolUtils.success(
		"Added transition '%s' → '%s' (%s, xfade %.2fs) — save the scene to persist" % [
			from_state, to_state, switch_mode_arg, transition.xfade_time,
		],
		{
			"tree_path": tree_path,
			"from_state": from_state,
			"to_state": to_state,
			"switch_mode": switch_mode_arg,
			"xfade_time": transition.xfade_time,
			"advance_mode": advance_mode_arg,
			"advance_condition": advance_condition,
			"transition_count": sm.get_transition_count(),
		}
	)


# Returns "" if the endpoint is valid, else an error message. `is_source`
# distinguishes "Start" (source-only) from "End" (destination-only).
func _validate_endpoint(sm: AnimationNodeStateMachine, state: String, is_source: bool) -> String:
	if state == "Start":
		if is_source:
			return ""
		return "'Start' is the entry point — it can only be a from_state, not a to_state"
	if state == "End":
		if not is_source:
			return ""
		return "'End' is a terminal sink — it can only be a to_state, not a from_state"
	if not sm.has_node(StringName(state)):
		return "State '%s' does not exist in the state machine" % state
	return ""


func _state_hints(sm: AnimationNodeStateMachine) -> Array:
	var names: Array = []
	for n in sm.get_node_list():
		names.append(String(n))
	return [
		"Existing states: %s" % (", ".join(names) if not names.is_empty() else "none"),
		"Add a state first with add_state_machine_state",
		"'Start' (as from_state) and 'End' (as to_state) are always available",
	]
