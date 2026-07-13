extends SceneTree

# Headless gameplay-probe entry point. Launched by the run_gameplay_probe
# tool as:
#
#   godot --headless --path <project> \
#       -s res://addons/com.gladekit.mcp-bridge/probe/gameplay_probe_runner.gd \
#       -- --gladekit-probe-config=<base64 JSON>
#
# A `-s` script replaces the main loop, so no scene loads on boot; we load
# the target scene ourselves, then attach a GameplayProbe node as a SIBLING
# of the scene (a direct child of root) so the probe survives an in-game
# change_scene_to_file. The probe drives the configured input schedule,
# samples the tracked body, prints a single machine-readable
# GLADEKIT_PROBE_REPORT line to stdout, and quits.
#
# Contract with the caller: every run prints exactly one
# "GLADEKIT_PROBE_REPORT: {json}" line — setup failures print a
# completed=false report before quitting, so the absence of the line means
# the process died hard (crash / watchdog kill), never a silent skip.

const GameplayProbe = preload("res://addons/com.gladekit.mcp-bridge/probe/gameplay_probe.gd")

const CONFIG_ARG_PREFIX := "--gladekit-probe-config="


func _initialize() -> void:
	var config := _parse_config_arg()
	if config.is_empty():
		_fail_fast("missing or unparseable %s argument" % CONFIG_ARG_PREFIX)
		return
	var scene_path := String(config.get("scene", ""))
	if scene_path.is_empty():
		_fail_fast("probe config carries no scene path")
		return
	if not ResourceLoader.exists(scene_path):
		_fail_fast("scene '%s' does not exist" % scene_path)
		return
	var packed = load(scene_path)
	if packed == null or not (packed is PackedScene):
		_fail_fast("scene '%s' is not a loadable PackedScene" % scene_path)
		return
	var instance: Node = packed.instantiate()
	if instance == null:
		_fail_fast("scene '%s' failed to instantiate" % scene_path)
		return
	root.add_child(instance)
	# Keep get_tree().current_scene working for game scripts that use it
	# (respawn / reload_current_scene patterns).
	current_scene = instance
	var probe: Node = GameplayProbe.new()
	probe.name = "GladeKitGameplayProbe"
	probe.config = config
	# Added AFTER the scene so the probe processes after game scripts each
	# frame; input pressed by the probe is seen by the game the next frame.
	root.add_child(probe)
	print("GLADEKIT_PROBE_BOOT scene=%s" % scene_path)


func _parse_config_arg() -> Dictionary:
	for arg in OS.get_cmdline_user_args():
		var s := String(arg)
		if not s.begins_with(CONFIG_ARG_PREFIX):
			continue
		var raw := Marshalls.base64_to_utf8(s.substr(CONFIG_ARG_PREFIX.length()))
		if raw.is_empty():
			return {}
		var parsed = JSON.parse_string(raw)
		if parsed is Dictionary:
			return parsed
		return {}
	return {}


func _fail_fast(reason: String) -> void:
	var report := {
		"probe": "gameplay",
		"completed": false,
		"problems": ["probe setup failed: %s" % reason],
	}
	print("GLADEKIT_PROBE_REPORT: %s" % JSON.stringify(report))
	quit(1)
