extends RefCounted

# Abstract base for all bridge tools. Concrete tools inherit via:
#     extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"
#
# Set `tool_name` and `requires_edit_mode` in `_init()`. Override `execute()`.
# Optionally set `min_godot_version` for engine-version-gated tools.

# The string name the agent and registry use to address this tool.
# Must be unique across all registered tools and use snake_case.
var tool_name: String = ""

# When true, the bridge refuses to dispatch this tool while Godot is playing
# a scene. Set to false for read-only tools (queries, hierarchy reads, console
# log reads, etc.) that are safe during play mode.
var requires_edit_mode: bool = true

# Optional version gate. Empty = no gate, runs on all supported Godot
# versions (>= 4.3 since that's our minimum). Set to "4.4" (or higher) for
# tools that depend on APIs introduced in a specific engine version
# (e.g. ResourceUID handling, only available 4.4+). The bridge refuses
# dispatch with a structured error on older engines.
var min_godot_version: String = ""


# Subclasses MUST override this. Should return a Dictionary with at least:
#   {"success": bool, "message": String, ...extras}
# Use the tool_utils helpers (success() / error()) to build the shape.
func execute(_args: Dictionary) -> Dictionary:
	return {
		"success": false,
		"error": "Tool '%s' has no execute() implementation" % tool_name,
		"message": "Tool '%s' has no execute() implementation" % tool_name,
	}


# ── Async tools (network downloads, long-running jobs) ─────────────────────
# Most tools are synchronous: execute() does the work and returns the final
# result in one editor tick. A few (e.g. asset downloads) must NOT block the
# editor's main thread for seconds, so they run their slow work on a worker
# Thread and report completion across editor ticks.
#
# Protocol:
#   1. execute() kicks off the background work and returns a Dictionary that
#      includes "async_pending": true (alongside "success": true). The bridge
#      does NOT treat that return as the final answer or send it to the client.
#   2. The bridge calls poll() once per editor tick. While the job is still
#      running, poll() returns {} (empty). When finished, poll() returns the
#      final result Dictionary (with a "success" key) — that becomes the single
#      response sent to the client.
#
# A synchronous tool never sets "async_pending" and never has poll() called,
# so this base implementation (always-empty) is safe to inherit untouched.
func poll() -> Dictionary:
	return {}
