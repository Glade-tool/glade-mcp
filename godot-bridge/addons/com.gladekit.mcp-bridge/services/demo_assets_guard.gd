extends RefCounted

# Path-write guard for "demo asset" directories. By default the bridge
# refuses to write to res://addons/com.gladekit.mcp-bridge/demo_assets/**
# so example/tutorial content shipped with the addon can't be accidentally
# overwritten by an agent.
#
# Per-project override (persists in project.godot):
#   gladekit/allow_demo_asset_writes = true
#
# Per-process override (no persistence):
#   GLADEKIT_GODOT_ALLOW_DEMO_WRITES=1
#
# Mirrors GladeAgenticAI.Services.DemoAssetsGuard from the Unity bridge.
# Unity uses EditorPrefs (per-user); Godot we use ProjectSettings
# (per-project) — matches the design-doc decision because the demo assets
# are tied to the addon install, not to the developer machine.

# Typed Array[String] literal (a constant expression) rather than a
# PackedStringArray(...) constructor (which is NOT const-evaluable in GDScript).
const PROTECTED_PREFIXES: Array[String] = [
	"res://addons/com.gladekit.mcp-bridge/demo_assets/",
]

const SETTING_KEY := "gladekit/allow_demo_asset_writes"
const ENV_KEY := "GLADEKIT_GODOT_ALLOW_DEMO_WRITES"


static func writes_allowed() -> bool:
	var env := OS.get_environment(ENV_KEY).strip_edges()
	if env == "1" or env.to_lower() == "true":
		return true
	if ProjectSettings.has_setting(SETTING_KEY):
		return bool(ProjectSettings.get_setting(SETTING_KEY))
	return false


# Returns "" if the path is writable, or a reason string if it's protected.
static func check_write(path: String) -> String:
	if writes_allowed():
		return ""
	var normalized := path.strip_edges()
	for prefix in PROTECTED_PREFIXES:
		if normalized.begins_with(prefix):
			return (
				"path '%s' is under a protected demo-asset directory ('%s'). "
				+ "Set ProjectSettings['%s']=true or env %s=1 to allow overwriting demo content."
			) % [normalized, prefix, SETTING_KEY, ENV_KEY]
	return ""
