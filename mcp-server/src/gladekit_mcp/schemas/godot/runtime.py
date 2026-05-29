"""
Godot runtime / process control tools (7 tools).

Three observability tools (get_play_mode_state, get_selection,
get_godot_console_logs) plus a four-tool process control surface:

  run_project / get_debug_output / stop_project — spawn a headless
    Godot subprocess that runs the project (or a specific scene),
    drain its stdout/stderr non-blockingly while it runs, then kill
    it. The bridge keeps the editor alive in parallel via per-session
    background drainer threads, so the agent can iterate on the
    scene WHILE watching the running game.

  launch_editor — spawn a separate editor instance on a different
    project (useful for opening a freshly-scaffolded project).

Session lifecycle: run_project returns a session_id; pass it to
get_debug_output (drain new output, non-blocking) and stop_project
(kill + final drain).
"""

from typing import Dict, List

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "get_play_mode_state",
            "description": (
                "Read whether the editor is currently playing a scene, the edited scene's "
                "path, and which scene is being played. Read-only — safe in any mode. "
                "Use to decide whether scene-mutating tools are safe to call "
                "(they're refused during play with a structured error)."
            ),
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_selection",
            "description": (
                "Read the nodes currently selected in the editor's Scene dock as "
                "scene-relative paths. Useful for 'do X to the selected node' workflows. "
                "Read-only — safe in any mode."
            ),
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_godot_console_logs",
            "description": (
                "Tail the editor's log file (user://logs/godot.log). Read-only. "
                "Supports a max_lines cap and a case-insensitive filter substring. "
                "Use to debug runtime errors after a play session, or to see what "
                "Godot wrote during script reloads."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "max_lines": {
                        "type": "integer",
                        "description": "How many trailing lines to return. Default 200, capped 2000.",
                    },
                    "filter": {
                        "type": "string",
                        "description": "Case-insensitive substring; only matching lines are returned.",
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_project",
            "description": (
                "Spawn a headless Godot child process to run the project (or a specific "
                "scene) and start draining its stdout/stderr in the background. Returns "
                "a session_id immediately; the editor stays alive and responsive while "
                "the child runs. Use get_debug_output to drain new output, stop_project "
                "to kill it. Use this for live playtest feedback loops."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "scene": {
                        "type": "string",
                        "description": (
                            "Optional res:// path to a .tscn to launch. Defaults to the "
                            "project's main scene from project.godot."
                        ),
                    },
                    "extra_args": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Additional CLI args to pass through to godot.",
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "stop_project",
            "description": (
                "Kill a play session started by run_project. Returns final drained "
                "stdout/stderr so the agent sees any last-second output."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "session_id": {
                        "type": "string",
                        "description": "Session id returned by run_project.",
                    },
                },
                "required": ["session_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_debug_output",
            "description": (
                "Drain currently-buffered stdout/stderr from a running play session "
                "(non-blocking). Returns only NEW output since the last drain (delta "
                "semantics — repeated calls don't return the same lines twice)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "session_id": {
                        "type": "string",
                        "description": "Session id returned by run_project.",
                    },
                },
                "required": ["session_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "launch_editor",
            "description": (
                "Spawn a separate Godot editor instance on a different project. The new "
                "editor is fully detached — it inherits no state from the current bridge. "
                "Use for onboarding flows or to open a freshly-scaffolded project."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "project_path": {
                        "type": "string",
                        "description": ("Absolute filesystem path to a directory containing project.godot."),
                    },
                },
                "required": ["project_path"],
            },
        },
    },
]
