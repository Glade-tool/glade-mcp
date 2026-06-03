extends RefCounted

# Observation lifecycle for the runtime-event stream.
#
# Mirrors the Unity bridge's PlayModeObserver — the "is the agent currently
# watching for runtime errors?" toggle plus the baseline cursor snapshot
# that makes arming non-retroactive (a fresh start_runtime_observation
# shouldn't surface a 10-minute-old error).
#
# Process model difference from Unity: the Unity observer also tracks
# EditorApplication.playModeStateChanged transitions because Unity's play
# session runs inside the editor's domain. Godot's play session is a
# separate process spawned by PlaySessionManager, so "is playing" is read
# from PlaySessionManager.list_sessions() at query time — there's no
# editor-side play-mode transition callback to subscribe to.

const RuntimeLogStream = preload("res://addons/com.gladekit.mcp-bridge/services/runtime_log_stream.gd")

static var _observation_active: bool = false
static var _observation_start_cursor: int = 0
static var _observation_start_timestamp: float = 0.0


# Arms observation and snapshots the current RuntimeLogStream cursor.
# Idempotent: a second call refreshes the baseline (useful when the
# caller reconnects mid-session and wants to ignore everything observed
# during the disconnect).
static func start_observation() -> void:
	_observation_active = true
	_observation_start_cursor = RuntimeLogStream.latest_cursor()
	_observation_start_timestamp = Time.get_unix_time_from_system()


# Disarms observation. The ring buffer keeps recording; this just tells
# the bridge the caller is no longer interested.
static func stop_observation() -> void:
	_observation_active = false


static func is_observation_active() -> bool:
	return _observation_active


static func observation_start_cursor() -> int:
	return _observation_start_cursor


static func observation_start_timestamp() -> float:
	return _observation_start_timestamp


static func reset() -> void:
	_observation_active = false
	_observation_start_cursor = 0
	_observation_start_timestamp = 0.0
