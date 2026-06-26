"""
Godot runtime / process control tools (10 tools).

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

Plus three structured runtime-event observation tools
(start_runtime_observation, stop_runtime_observation,
get_runtime_events) that surface play-session errors as cursored,
fingerprinted events for incremental polling. The bridge parses
ERROR / SCRIPT ERROR / USER SCRIPT ERROR lines + their stack frames
out of each session's stderr; warnings and plain stdout are dropped.

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
                "to kill it. Use this for live playtest feedback loops. "
                "\n\n"
                "Auto-saves the edited scene before spawning (auto_save=true default) "
                "so the subprocess loads the latest in-memory edits, not the stale disk "
                "state. Refuses a second concurrent session by default to prevent the "
                "'two play windows' footgun when retrying; pass allow_multiple=true if "
                "you genuinely need two sessions. "
                "\n\n"
                "Recommended workflow for diagnostics: run_project → start_runtime_observation "
                "(if not already) → wait briefly (the subprocess takes ~1-2s to boot and "
                "fire _ready) → get_runtime_events → stop_project LAST (stop erases the "
                "session, so call get_debug_output / get_runtime_events first)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "scene": {
                        "type": "string",
                        "description": (
                            'Which scene to run. Use "current" to run the scene open in '
                            "the editor — REQUIRED when verifying a change you just made, "
                            "because the project's main scene is often a menu that does not "
                            "include the node you edited (so it would run clean while your "
                            "edit went untested). A res:// path runs that specific scene. "
                            "Omit to run the project's main scene from project.godot."
                        ),
                    },
                    "verify": {
                        "type": "boolean",
                        "description": (
                            "Run a bounded headless pass for error capture (adds "
                            "--headless --quit-after so the process exits on its own and "
                            "flushes its output). Set true when verifying a gameplay "
                            "change — it makes get_debug_output a reliable clean/dirty "
                            "check, where a long indefinite run may never surface a small "
                            "runtime error. Default false (interactive playtest)."
                        ),
                    },
                    "extra_args": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Additional CLI args to pass through to godot.",
                    },
                    "auto_save": {
                        "type": "boolean",
                        "description": (
                            "Save the edited scene before spawning so the subprocess loads "
                            "your latest changes from disk. Default true. Set false to run "
                            "the on-disk version as-is."
                        ),
                    },
                    "allow_multiple": {
                        "type": "boolean",
                        "description": (
                            "Allow a second concurrent play session. Default false — without "
                            "this the tool refuses if any session is still running, so a retry "
                            "doesn't open a second game window."
                        ),
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
                "stdout/stderr so the agent sees any last-second output. "
                "Call this LAST in a diagnostics flow — it erases the session from "
                "the manager, so any subsequent get_debug_output(session_id) returns "
                "'session not found'. Call get_runtime_events / get_debug_output "
                "before stop_project, not after. "
                "\n\n"
                "Pass session_id (the string from run_project, e.g. '1') — NOT pid "
                "(the OS process id, e.g. 23696). If you only have the pid, pass it "
                "as the pid arg instead — the tool resolves either."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "session_id": {
                        "type": "string",
                        "description": (
                            "Bridge session identifier from run_project's response (e.g. '1', '2', …). NOT the OS pid."
                        ),
                    },
                    "pid": {
                        "type": "integer",
                        "description": (
                            "Fallback: kill whichever session is running this OS pid. "
                            "Use only when you have the pid but not the session_id."
                        ),
                    },
                },
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
    {
        "type": "function",
        "function": {
            "name": "start_runtime_observation",
            "description": (
                "Arm structured runtime-event observation. Snapshots the current "
                "runtime-event cursor so subsequent get_runtime_events polls return only "
                "events from this point forward — arming should not retroactively "
                "surface a 10-minute-old error. Idempotent: re-arming refreshes the "
                "baseline cursor (useful after a reconnect). Read-only — safe in any "
                "mode. The bridge parses errors out of active play-session stderr; "
                "warnings and plain stdout are dropped. Returns observation_active, "
                "start_cursor, ring_buffer_size, is_playing."
            ),
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "stop_runtime_observation",
            "description": (
                "Disarm structured runtime-event observation. The ring buffer keeps "
                "recording errors from any active play sessions; this just tells the "
                "bridge the caller is no longer interested. Read-only — safe in any "
                "mode."
            ),
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_runtime_events",
            "description": (
                "Pull structured runtime errors captured since since_cursor. Read-only. "
                "Each event has cursor (monotonic int), message, stack_trace, log_type "
                "(ERROR | SCRIPT_ERROR | USER_ERROR | USER_SCRIPT_ERROR), timestamp "
                "(unix seconds), and fingerprint (message + stack hash, stable within "
                "a session for client-side dedup). Designed for incremental polling — "
                "pass the prior response's next_cursor on each call so you only see new "
                "events. When play_mode_active is false, the runner should stop polling. "
                "Pulls fresh stderr from active play sessions before reading the ring "
                "buffer, without consuming the user-facing buffer that get_debug_output "
                "reads. "
                "\n\n"
                "When called immediately after run_project, pass wait_ms (e.g. 2000) — "
                "the subprocess takes ~500ms-2s to boot and fire _ready, so a non-waiting "
                "poll right after spawn returns empty even when errors are about to fire. "
                "\n\n"
                "Self-diagnosis fields in the response: raw_stderr_bytes/raw_stdout_bytes "
                "show how many bytes the bridge captured from subprocess pipes. If events "
                "is empty AND raw_stderr_bytes > 0, the parser missed a new prefix — check "
                "raw_stderr_tail. If both are 0, the subprocess didn't write anything to "
                "stderr (libc buffering, no errors fired, or pipe issue)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "since_cursor": {
                        "type": "integer",
                        "description": (
                            "Return events with cursor > this value. Pass 0 to read "
                            "every event currently in the buffer; pass the prior "
                            "next_cursor for incremental polls."
                        ),
                    },
                    "limit": {
                        "type": "integer",
                        "description": (
                            "Maximum events returned per call. Default 200, hard-capped "
                            "at 2000. Events past the limit remain for the next poll."
                        ),
                    },
                    "wait_ms": {
                        "type": "integer",
                        "description": (
                            "Optional blocking wait (0-5000ms) for new events to arrive. "
                            "The tool re-drains every 100ms until events appear or the "
                            "deadline passes. Use right after run_project (try 2000-3000) "
                            "so the first poll doesn't beat the subprocess to _ready. "
                            "Default 0 = no wait."
                        ),
                    },
                },
            },
        },
    },
]
