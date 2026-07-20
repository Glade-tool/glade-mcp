"""
Runtime category tools — Live Loop autonomous fix-on-error during Play Mode.

Surfaces Unity Play Mode lifecycle and the runtime error stream to MCP
clients (Cursor, Claude Code, Windsurf), plus the apply_queued_fix
idempotent dispatcher used when accepting a proposed fix.
"""

from typing import Dict, List

CATEGORY = {
    "name": "runtime",
    "display_name": "Runtime & Live Loop",
    "keywords": [
        "play",
        "play mode",
        "playmode",
        "running",
        "stop",
        "live loop",
        "runtime error",
        "runtime exception",
        "null reference",
        "nullref",
        "nre",
        "fix",
        "apply fix",
        "watch errors",
        "observe errors",
        "console",
        "exception",
    ],
}

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "start_runtime_observation",
            "description": (
                "Arm Live Loop runtime observation. Snapshots the current "
                "runtime-event cursor so subsequent get_runtime_events polls "
                "return only new errors. Idempotent — safe to call after a "
                "reconnect to refresh the baseline. Returns startCursor + "
                "isPlaying."
            ),
            "parameters": {
                "type": "object",
                "properties": {},
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "stop_runtime_observation",
            "description": (
                "Disarm Live Loop runtime observation. The bridge keeps "
                "recording events; this just signals the runner is no longer "
                "interested. Use when ending a session or explicitly halting "
                "the loop."
            ),
            "parameters": {
                "type": "object",
                "properties": {},
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_runtime_events",
            "description": (
                "Pull runtime errors / exceptions captured since sinceCursor. "
                "Read-only. Returns events[] (each with cursor, message, "
                "stackTrace, logType, timestamp, fingerprint), nextCursor, "
                "playModeActive, observationActive, lastTransition. Pass the "
                "previous response's nextCursor on the next poll. When "
                "playModeActive is false, the runner should stop polling."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "sinceCursor": {
                        "type": "integer",
                        "description": (
                            "Return events with cursor > this value. Pass 0 "
                            "to read every event currently in the buffer; "
                            "pass the prior nextCursor for incremental polls."
                        ),
                    },
                    "limit": {
                        "type": "integer",
                        "description": (
                            "Maximum events returned per call (default 200). "
                            "Events past the limit remain for the next poll."
                        ),
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "start_playability_probe",
            "description": (
                "Play-test a gameplay change to catch runtime errors before "
                "finishing. Enters Play mode, runs the current scene for a few "
                "seconds, and captures anything logged as an Error/Exception "
                "(e.g. a NullReferenceException in Awake/Start/Update that "
                "compiled fine but only throws at runtime). Use bootOnly=true "
                "for a general 'does it run without throwing' check on any "
                "gameplay script — it does NOT require a Player object or drive "
                "input. Two-phase: this arms + enters Play and returns "
                "immediately with status='running'; then poll "
                "get_playability_probe_result after ~2-3s for the outcome. "
                "Requires the new Input System; on a legacy-input project it "
                "returns status='not_applicable' (fall back to "
                "get_runtime_events to read logged errors instead)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "bootOnly": {
                        "type": "boolean",
                        "description": (
                            "True (recommended for verifying an arbitrary "
                            "gameplay change): just boot the scene and watch for "
                            "runtime errors, no target/input. False: also drive "
                            "a movement controller and report motion metrics."
                        ),
                    },
                    "holdSeconds": {
                        "type": "number",
                        "description": "Seconds to let the scene run (default 3 in bootOnly).",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_playability_probe_result",
            "description": (
                "Poll for the result of start_playability_probe. Read-only. "
                "Returns status ('running' | 'done' | 'error' | "
                "'not_applicable'), threw (bool — did the run log any runtime "
                "error), and errors (the captured error lines, empty on a clean "
                "run). Poll again while status='running' (the probe simulates "
                "for a few seconds). A result with threw=false and no error "
                "lines is a clean run."
            ),
            "parameters": {
                "type": "object",
                "properties": {},
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_play_mode_state",
            "description": (
                "Get Unity Play Mode state. Read-only. Returns isPlaying, "
                "willChangePlayMode, lastTransition, last enter/exit "
                "timestamps, observationActive, observationStartCursor. Use "
                "to detect Play exit (so queued fixes can be applied) and "
                "Play re-entry during APPLYING."
            ),
            "parameters": {
                "type": "object",
                "properties": {},
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "apply_queued_fix",
            "description": (
                "Apply a Live Loop FixProposal by dispatching each change "
                "through the existing tool dispatcher. Idempotent: a second "
                "call with the same proposalId returns alreadyApplied:true "
                "with the prior result and does NOT re-execute. Use after "
                "Play exits or the user accepts a proposed fix."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "proposalId": {
                        "type": "string",
                        "description": (
                            "Idempotency key. Identifies this proposal "
                            "across retries; second apply returns "
                            "alreadyApplied:true."
                        ),
                    },
                    "summary": {
                        "type": "string",
                        "description": (
                            "One-line user-facing description of what the "
                            "fix does. Stored on the apply tracker for "
                            "diagnostics and the renderer's status panel."
                        ),
                    },
                    "changes": {
                        "type": "array",
                        "description": (
                            "Ordered list of tool calls to dispatch. Each "
                            "change is attempted; first-error does NOT "
                            "short-circuit. Per-change results returned in "
                            "the response."
                        ),
                        "items": {
                            "type": "object",
                            "properties": {
                                "toolName": {
                                    "type": "string",
                                    "description": (
                                        "Name of an existing Unity tool (e.g. modify_script, set_component_property)."
                                    ),
                                },
                                "args": {
                                    "type": "object",
                                    "description": (
                                        "Arguments to pass to the tool. Same shape as a direct call to that tool."
                                    ),
                                },
                                "rationale": {
                                    "type": "string",
                                    "description": (
                                        "Optional one-line reason for this "
                                        "specific change. Surfaced to the "
                                        "user in the apply summary."
                                    ),
                                },
                            },
                            "required": ["toolName", "args"],
                        },
                    },
                },
                "required": ["proposalId", "changes"],
            },
        },
    },
]
