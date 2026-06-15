"""
Godot audio tools (2 tools).

`create_audio_player` places an AudioStreamPlayer (non-positional — music /
UI / ambience) or a positional AudioStreamPlayer2D / 3D in the scene, and
optionally assigns an imported stream in the same call. It is the wiring step
between importing an audio file and a sound that actually plays.
`set_audio_player_properties` is the mutate counterpart for an existing player.

To swap the clip on a player after creation, use
`set_node_resource(property="stream", resource_path=...)`.
"""

from typing import Dict, List

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "create_audio_player",
            "description": (
                "Add an audio player to the scene and optionally wire a stream to it — "
                "the step that makes an imported res://assets/audio/** file actually "
                "play. Default (positional=false) creates a non-positional "
                "AudioStreamPlayer: the right choice for background music, ambience, and "
                "UI sounds (audible everywhere, never attenuates). Set positional=true "
                "for world SFX (a coin pickup, an enemy growl) — it makes an "
                "AudioStreamPlayer2D or AudioStreamPlayer3D, with the family inferred "
                "from the scene's root (override with `space`)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Node name. Defaults to the stream's filename, else the Godot class.",
                    },
                    "parent_path": {
                        "type": "string",
                        "description": "Scene-relative parent. Default scene root.",
                    },
                    "stream": {
                        "type": "string",
                        "description": (
                            "res:// path to an AudioStream (.ogg/.mp3/.wav) to assign now. "
                            "Must exist and load as audio. Omit for an empty player."
                        ),
                    },
                    "positional": {
                        "type": "boolean",
                        "description": (
                            "false (default) → AudioStreamPlayer (music/UI, plays "
                            "everywhere). true → positional AudioStreamPlayer2D/3D that "
                            "attenuates by distance."
                        ),
                    },
                    "space": {
                        "type": "string",
                        "description": (
                            "Positional family: '2d' or '3d'. Inferred from the scene root "
                            "when omitted; only used when positional=true."
                        ),
                        "enum": ["2d", "3d"],
                    },
                    "volume_db": {
                        "type": "number",
                        "description": "Output volume in decibels (0 = unchanged, -80 = silent). Default 0.",
                    },
                    "autoplay": {
                        "type": "boolean",
                        "description": "Start playing when the scene loads. Default false.",
                    },
                    "bus": {
                        "type": "string",
                        "description": (
                            "Target audio bus. Default 'Master'. An unknown bus is applied but flagged in bus_warning."
                        ),
                    },
                    "pitch_scale": {
                        "type": "number",
                        "description": "Playback speed / pitch multiplier. Default 1.",
                    },
                    "position": {
                        "type": "string",
                        "description": "Initial position 'x,y' (2D) / 'x,y,z' (3D). Positional players only.",
                    },
                    "max_distance": {
                        "type": "number",
                        "description": "Audible range (positional only; 0 = no limit).",
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_audio_player_properties",
            "description": (
                "Mutate an existing audio player (AudioStreamPlayer / AudioStreamPlayer2D "
                "/ AudioStreamPlayer3D). Sets only the properties passed; omitted args "
                "leave current values untouched, so 'turn the music down' is one call. "
                "Class-aware: max_distance applies to positional 2D/3D players only — on "
                "a non-positional player it lands in `ignored_properties` with a reason "
                "and the call still succeeds for the args that DID apply. To swap the "
                "clip itself use set_node_resource(property='stream', ...)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "node_path": {
                        "type": "string",
                        "description": "Scene-relative path to the target audio player.",
                    },
                    "volume_db": {
                        "type": "number",
                        "description": "Output volume in decibels (0 = unity, -80 = silent).",
                    },
                    "autoplay": {
                        "type": "boolean",
                        "description": "Play automatically when the scene loads.",
                    },
                    "bus": {
                        "type": "string",
                        "description": (
                            "Target audio bus. A bus missing from the project is ignored "
                            "with a reason (it would route to nothing)."
                        ),
                    },
                    "pitch_scale": {
                        "type": "number",
                        "description": "Playback speed / pitch multiplier.",
                    },
                    "max_distance": {
                        "type": "number",
                        "description": "Audible range. AudioStreamPlayer2D / 3D only (0 = no limit).",
                    },
                },
                "required": ["node_path"],
            },
        },
    },
]
