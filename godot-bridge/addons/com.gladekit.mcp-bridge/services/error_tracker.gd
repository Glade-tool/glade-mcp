extends RefCounted

# Accumulates tool failures per Godot session so an MCP client can read the
# recent error history (via the bridge's diagnostics/recent_errors endpoint)
# and avoid repeating mistakes on retry.
#
# Mirrors the ErrorTracker service from the Unity bridge.
# State is process-local — wiped on editor restart or addon hot-reload.
# That's intentional: a fresh editor is a fresh session.

const MAX_ENTRIES := 50  # ring buffer cap; older entries drop off

static var _entries: Array = []  # newest-last


static func record(tool_name: String, error_message: String, args: Dictionary = {}) -> void:
	if tool_name.is_empty() and error_message.is_empty():
		return
	_entries.append({
		"timestamp_ms": Time.get_ticks_msec(),
		"tool_name": tool_name,
		"error": error_message,
		"args_keys": args.keys() if args != null else [],
	})
	if _entries.size() > MAX_ENTRIES:
		_entries = _entries.slice(_entries.size() - MAX_ENTRIES)


static func recent(limit: int = 10) -> Array:
	if limit <= 0:
		return []
	var n: int = min(limit, _entries.size())
	return _entries.slice(_entries.size() - n)


static func clear() -> void:
	_entries.clear()


static func count() -> int:
	return _entries.size()
