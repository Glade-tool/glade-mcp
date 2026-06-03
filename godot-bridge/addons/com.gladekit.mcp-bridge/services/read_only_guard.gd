extends RefCounted

# Read-only mode: when active, the bridge refuses every tool whose name is
# NOT in READ_ONLY_TOOLS. Used for "show me the project but don't change it"
# sessions (audit, inspection, code review, demos).
#
# Toggle via ProjectSettings (per-project, persists in project.godot):
#   gladekit/read_only_mode = true
# or via OS env override (per-process, no persistence):
#   GLADEKIT_GODOT_READ_ONLY=1
#
# Mirrors the Unity bridge's READ_ONLY_TOOLS constant. New read-only tools
# must be added here AND have requires_edit_mode=false on the tool itself.

# Typed Array[String] literal (a constant expression) rather than a
# PackedStringArray(...) constructor (which is NOT const-evaluable in GDScript).
const READ_ONLY_TOOLS: Array[String] = [
	# Scene/Node reads
	"get_scene_tree",
	"get_node_info",
	"find_nodes",
	# Script reads
	"get_script_content",
	"find_scripts",
	# Runtime/observability reads
	"get_godot_console_logs",
	"get_play_mode_state",
	"get_selection",
	"get_debug_output",
	"get_runtime_events",
	"start_runtime_observation",
	"stop_runtime_observation",
	# UID reads
	"get_uid",
	# Signal reads
	"list_signal_connections",
	# Project introspection reads
	"get_project_info",
	"list_assets",
	# UI reads (v0.5.0)
	"list_ui_hierarchy",
	# Lighting / Environment reads (v0.5.3)
	"get_light_info",
	"get_world_environment",
]

const SETTING_KEY := "gladekit/read_only_mode"
const ENV_KEY := "GLADEKIT_GODOT_READ_ONLY"


static func is_read_only_mode() -> bool:
	var env := OS.get_environment(ENV_KEY).strip_edges()
	if env == "1" or env.to_lower() == "true":
		return true
	if ProjectSettings.has_setting(SETTING_KEY):
		return bool(ProjectSettings.get_setting(SETTING_KEY))
	return false


static func is_allowed(tool_name: String) -> bool:
	if not is_read_only_mode():
		return true
	return READ_ONLY_TOOLS.has(tool_name)
