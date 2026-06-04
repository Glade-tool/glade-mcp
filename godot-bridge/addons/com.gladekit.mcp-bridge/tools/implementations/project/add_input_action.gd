extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Defines (or replaces) a custom InputMap action and binds physical keyboard
# keys to it. The action is persisted to project.godot via ProjectSettings —
# so it survives restarts and appears under Project Settings > Input Map — AND
# mirrored into the live InputMap singleton, so it works the moment the project
# runs without an editor restart.
#
# This closes a common gap: movement / jump / interact scripts reference named
# actions (`Input.is_action_pressed("move_forward")`), but a fresh Godot
# project ships with only the engine `ui_*` defaults. Without a way to create
# actions, an agent either writes scripts against actions that don't exist
# (runtime errors on every frame) or is forced into raw key polling. With this
# tool it can set up the action map first, then write idiomatic action-based
# input code.
#
# Args:
#   action_name: String  (required) — e.g. "move_forward", "jump". snake_case
#                by convention; any non-empty string is accepted.
#   keys:        Array[String] (required) — key names bound to the action,
#                e.g. ["W", "Up"]. Parsed via OS.find_keycode_from_string, so
#                editor-style names work: "Space", "Escape", "Shift", "Enter",
#                arrow keys ("Up"). Bound as PHYSICAL keys so WASD survives
#                non-QWERTY layouts.
#   deadzone:    float  (optional, default 0.5) — analog deadzone, clamped 0..1.
#   overwrite:   bool   (optional, default true) — when the action already
#                exists, replace its event list. Set false to fail instead of
#                clobbering an existing action.
#
# Response payload:
#   action_name: String
#   keys:        Array[String] — normalized key names actually bound
#   created:     bool — true if the action was new, false if it was updated

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const DEFAULT_DEADZONE := 0.5


func _init() -> void:
	tool_name = "add_input_action"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var action_name: String = ToolUtils.parse_string_arg(args, "action_name").strip_edges()
	if action_name.is_empty():
		return ToolUtils.error("action_name is required")

	var raw_keys = args.get("keys", null)
	if not (raw_keys is Array) or (raw_keys as Array).is_empty():
		return ToolUtils.error_with_solutions(
			"keys is required and must be a non-empty array of key names",
			[
				'Pass keys as an array, e.g. {"action_name": "move_forward", "keys": ["W", "Up"]}',
				'Use editor-style key names: letters ("W"), "Space", "Escape", "Shift", "Enter", arrow keys ("Up").',
			]
		)

	# Resolve every key string to a keycode. Collect the unresolved ones so the
	# agent gets a precise, actionable error rather than a silently half-bound
	# action.
	var events: Array = []
	var bound_names: Array = []
	var invalid: Array = []
	for k in (raw_keys as Array):
		var key_str: String = str(k).strip_edges()
		if key_str.is_empty():
			continue
		var keycode: int = OS.find_keycode_from_string(key_str)
		if keycode == KEY_NONE:
			invalid.append(key_str)
			continue
		var ev := InputEventKey.new()
		# Physical keycode = position on the keyboard, so WASD stays WASD on
		# AZERTY/Dvorak/etc. The right default for movement bindings.
		ev.physical_keycode = keycode
		events.append(ev)
		bound_names.append(OS.get_keycode_string(keycode))

	if not invalid.is_empty():
		return ToolUtils.error_with_solutions(
			"Unrecognized key name(s): %s" % ", ".join(invalid),
			[
				'Use editor-style names: single letters/digits ("W", "1"), "Space", "Escape", "Enter", "Shift", "Ctrl", "Alt", "Tab", arrow keys ("Up"/"Down"/"Left"/"Right").',
				"Names are case-insensitive but must match Godot's keycode strings.",
			]
		)

	if events.is_empty():
		return ToolUtils.error("No valid keys to bind")

	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", true)
	var deadzone: float = clampf(ToolUtils.parse_float_arg(args, "deadzone", DEFAULT_DEADZONE), 0.0, 1.0)

	var setting := "input/" + action_name
	var existed: bool = ProjectSettings.has_setting(setting)
	if existed and not overwrite:
		return ToolUtils.error_with_solutions(
			"Input action '%s' already exists" % action_name,
			[
				"Pass overwrite=true to replace its key bindings.",
				"Choose a different action_name to add a separate action.",
			]
		)

	# 1) Persist to project.godot. Godot stores each action as
	#    {"deadzone": float, "events": [InputEvent, ...]} under input/<name>.
	ProjectSettings.set_setting(setting, {"deadzone": deadzone, "events": events})
	var save_err: int = ProjectSettings.save()
	if save_err != OK:
		return ToolUtils.error("Failed to save project settings (error %d)" % save_err)

	# 2) Mirror into the live InputMap — ProjectSettings.save() does not refresh
	#    the running editor's InputMap singleton, so without this the action
	#    wouldn't fire until the editor restarts.
	if InputMap.has_action(action_name):
		InputMap.action_erase_events(action_name)
	else:
		InputMap.add_action(action_name)
	InputMap.action_set_deadzone(action_name, deadzone)
	for ev in events:
		InputMap.action_add_event(action_name, ev)

	var verb := "Updated" if existed else "Created"
	return ToolUtils.success(
		"%s input action '%s' bound to %s" % [verb, action_name, ", ".join(bound_names)],
		{
			"action_name": action_name,
			"keys": bound_names,
			"created": not existed,
		}
	)
