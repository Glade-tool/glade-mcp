"""
Godot signal tools (3 tools).

Signals are Godot's idiomatic event mechanism — a Button declares a
`pressed` signal, an Area3D declares `body_entered`, etc. Wiring a signal
to a method is how most interactivity gets built. The tools here cover
the editor-time, scene-saved (CONNECT_PERSIST) flavor of wiring — the
kind you'd otherwise create through the Godot editor's Node panel.

For runtime-only connections (made and broken during gameplay), the
agent should write GDScript using `signal.connect(...)` instead — that's
a code concern, not an editor wiring concern.

Three tools, intentionally consolidated:

  connect_signal           — wire emitter.signal -> target.method
                             (persistent, scene-saved)
  list_signal_connections  — read existing wiring; also lists declared
                             signals via response_format="detailed"
  disconnect_signal        — remove a persistent connection

The standalone "list signals on a node" use case is folded into
list_signal_connections with response_format="detailed" — the agent
almost never wants signals without also wanting connection state, and
exposing them as separate tools just makes the agent choose between
two read endpoints that should have been one.
"""

from typing import Dict, List

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "connect_signal",
            "description": (
                "Wire a signal from an emitter node to a method on a target "
                "node. The connection is PERSISTENT — saved with the scene "
                ".tscn — so it ships with the game and survives reloads. "
                "Use this for editor-time wiring (e.g. \"connect the Button's "
                '`pressed` signal to a method on the parent Control"). For '
                "connections created/destroyed during gameplay, write GDScript "
                "using `signal.connect(...)` instead — this tool is not for "
                "runtime wiring.\n\n"
                "Both nodes must be in the currently edited scene. NodePaths "
                'are relative to the edited scene root (e.g. "UI/Button"). '
                "Refuses with `possible_solutions` listing the closest names "
                "if the signal isn't declared on the emitter or the method "
                "isn't defined on the target's script. If you're unsure which "
                "signals are available, call list_signal_connections with "
                'response_format="detailed" first.'
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "emitter_path": {
                        "type": "string",
                        "description": (
                            "Scene-relative NodePath of the node that emits the signal (e.g. 'UI/StartButton')."
                        ),
                    },
                    "signal_name": {
                        "type": "string",
                        "description": (
                            "Name of the signal as declared on the emitter (e.g. "
                            "'pressed' for Button, 'body_entered' for Area3D). Case-sensitive."
                        ),
                    },
                    "target_path": {
                        "type": "string",
                        "description": (
                            "Scene-relative NodePath of the receiver — the node whose "
                            "method gets called when the signal fires."
                        ),
                    },
                    "method_name": {
                        "type": "string",
                        "description": (
                            "Name of the method on the target node. Must already exist "
                            "on the target's attached script — connect_signal will refuse "
                            "to wire to a nonexistent method (otherwise the connection "
                            "would silently no-op at runtime). Convention: '_on_<emitter>_<signal>'."
                        ),
                    },
                    "flags": {
                        "type": "array",
                        "items": {"type": "string", "enum": ["deferred", "one_shot"]},
                        "description": (
                            "Optional connection modifiers. 'deferred' fires the call on "
                            "the next idle frame (safer when the handler may modify the "
                            "scene tree during the signal). 'one_shot' auto-disconnects "
                            "after the first fire. PERSIST is always set."
                        ),
                    },
                },
                "required": ["emitter_path", "signal_name", "target_path", "method_name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_signal_connections",
            "description": (
                "Read existing signal connections involving a node. Outgoing "
                "shows signals this node emits and what they're wired to; "
                "incoming shows signals from other nodes that target this "
                "node. Read-only and safe in play mode.\n\n"
                'Use response_format="detailed" to also list every signal '
                "*declared* on the node (whether connected or not) — that's "
                "the right call when planning a new connection and you need "
                "to know what's available. Use signal_name to narrow to one "
                "specific signal."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "node_path": {
                        "type": "string",
                        "description": ("Scene-relative NodePath of the node to inspect."),
                    },
                    "signal_name": {
                        "type": "string",
                        "description": (
                            "Optional — narrow the result to this signal only. "
                            "Useful when iterating on the wiring for one event."
                        ),
                    },
                    "direction": {
                        "type": "string",
                        "enum": ["out", "in", "both"],
                        "description": (
                            "'out' = signals this node emits and where they go; "
                            "'in' = signals from other nodes that target this node; "
                            "'both' = both (default). Scanning 'in' walks the scene tree, "
                            "so use 'out' when you only need outgoing."
                        ),
                    },
                    "response_format": {
                        "type": "string",
                        "enum": ["concise", "detailed"],
                        "description": (
                            "'concise' (default) returns only the connections list. "
                            "'detailed' additionally returns available_signals: every "
                            "signal *declared* on the node with its arg names and "
                            "current connection count — useful for planning."
                        ),
                    },
                },
                "required": ["node_path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "disconnect_signal",
            "description": (
                "Remove a persistent (scene-saved) signal connection. Inverse "
                "of connect_signal. All four identifying fields must match an "
                "existing connection exactly — call list_signal_connections "
                "first if you're unsure of the spelling. Refuses with a clear "
                "error if the connection doesn't exist (never silently "
                "no-ops — that's the exact bug we want to surface)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "emitter_path": {
                        "type": "string",
                        "description": "Scene-relative NodePath of the emitter.",
                    },
                    "signal_name": {
                        "type": "string",
                        "description": "Signal name on the emitter.",
                    },
                    "target_path": {
                        "type": "string",
                        "description": "Scene-relative NodePath of the receiver.",
                    },
                    "method_name": {
                        "type": "string",
                        "description": "Method on the receiver that's currently wired.",
                    },
                },
                "required": ["emitter_path", "signal_name", "target_path", "method_name"],
            },
        },
    },
]
