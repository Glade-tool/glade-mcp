"""
Godot animation tools (5 tools) — AnimationPlayer + Animation .tres
scaffolding.

The AnimationPlayer node itself + the Animation .tres are created via
existing tools — `create_node(type='AnimationPlayer', parent_path='...')`
and `create_resource(type='Animation', path='res://anim/jump.tres')`.
These five tools close the gap between "I have an empty player + an
empty animation" and "I have a playable animation library."

  add_animation_to_player    register an Animation .tres with a player
                             under a library + name (default library is
                             "", the conventional default).
  add_animation_track        add a track to an Animation: value (any
                             property), position_3d / rotation_3d /
                             scale_3d (Node3D transform), or method
                             (calls a function at keyframes).
  add_animation_keyframe     insert a keyframe at time T with value V.
                             Value parsing dispatches on track type.
  set_animation_properties   length / loop_mode / step on the Animation.
  get_animation_player_info  read-only: libraries + animations + state.

Composition flow for a typical scaffold (e.g., "add a 0.6s jump
animation on Player"):

    create_node(type='AnimationPlayer', parent_path='Player')
        -> AnimationPlayer node child
    create_resource(type='Animation', path='res://anim/jump.tres')
        -> empty Animation .tres
    add_animation_to_player(player_path='Player/AnimationPlayer',
                            animation_path='res://anim/jump.tres',
                            animation_name='jump')
    add_animation_track(animation_path='res://anim/jump.tres',
                        track_type='position_3d', node_path='..')
        -> track_index=0
    add_animation_keyframe(animation_path='res://anim/jump.tres',
                           track_index=0, time=0.0, value='0,0,0')
    add_animation_keyframe(animation_path='res://anim/jump.tres',
                           track_index=0, time=0.3, value='0,2,0')
    add_animation_keyframe(animation_path='res://anim/jump.tres',
                           track_index=0, time=0.6, value='0,0,0')
    set_animation_properties(animation_path='res://anim/jump.tres',
                             length=0.6, loop_mode='none')

The track's node_path is resolved relative to the AnimationPlayer's
`root_node` property (default ".."  — the player's parent). Use
get_animation_player_info to inspect the current root_node when
authoring tracks against a non-default setup.
"""

from typing import Dict, List

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "add_animation_to_player",
            "description": (
                "Register an Animation .tres with an AnimationPlayer so the player can "
                "play it by name. Required step after creating a fresh AnimationPlayer "
                "+ Animation .tres — the .tres exists as a file but the player has no "
                "reference to it until this call, so player.play('jump') would fail at "
                "runtime. If the library doesn't exist on the player, it's "
                'created (default library is "" — the conventional setup, where '
                "play('jump') resolves to /jump on the default library).\n\n"
                "The Animation .tres must already exist — create it via "
                "create_resource(type='Animation', path='res://...') first. The library "
                "stores a reference to the .tres, so editing the Animation later via "
                "add_animation_track / add_animation_keyframe doesn't require "
                "re-registering.\n\n"
                "Refuses to overwrite an existing entry — pick a different "
                "animation_name or remove the existing one in the editor first. The "
                "change persists when the scene is saved (the player's libraries dict "
                "is serialized into the .tscn)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "player_path": {
                        "type": "string",
                        "description": "Scene-relative NodePath of the AnimationPlayer node.",
                    },
                    "animation_path": {
                        "type": "string",
                        "description": "res:// path to an existing Animation .tres file.",
                    },
                    "animation_name": {
                        "type": "string",
                        "description": "Name to register the animation under (the agent later plays this name).",
                    },
                    "library_name": {
                        "type": "string",
                        "description": (
                            'Animation library name. Default "" (the conventional '
                            "default library). Multi-library splits are rare — typically "
                            "used for character variants."
                        ),
                    },
                },
                "required": ["player_path", "animation_path", "animation_name"],
            },
            "annotations": {
                "title": "Add Animation to Player",
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "add_animation_track",
            "description": (
                "Add a track to an Animation. A track binds a node + property to a "
                "stream of keyframes (added separately via add_animation_keyframe). "
                "Returns the new track_index, which subsequent keyframe calls reference. "
                "An empty track is silent during playback — follow each add_animation_track "
                "call with ≥2 add_animation_keyframe calls (one at t=0 for the start "
                "value and at least one more for the end value) so the track has values "
                "to interpolate between.\n\n"
                "Track types and node_path / property conventions:\n"
                "  value        — animate any property. node_path='Player', "
                "property='position:y' → addresses Player:position:y. Use for "
                "properties the dedicated transform tracks don't cover (modulate, "
                "alpha, custom shader params, exported floats).\n"
                "  position_3d  — Node3D position. node_path='Player' alone. More "
                "efficient than animating position via a value track.\n"
                "  rotation_3d  — Node3D rotation. Quaternion-typed keys.\n"
                "  scale_3d     — Node3D scale.\n"
                "  method       — call a method at each keyframe. The key's value is "
                "{method, args}.\n\n"
                "Track paths are resolved relative to the AnimationPlayer's "
                '`root_node` (default "..", i.e. the player\'s parent). To target the '
                "player's parent directly, use node_path='.'. To target a sibling of "
                "the parent, use the sibling name. Call get_animation_player_info to "
                "see the current root_node setting."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "animation_path": {
                        "type": "string",
                        "description": "res:// path to the Animation .tres.",
                    },
                    "track_type": {
                        "type": "string",
                        "description": "Track type — see description for semantics.",
                        "enum": ["value", "position_3d", "rotation_3d", "scale_3d", "method"],
                    },
                    "node_path": {
                        "type": "string",
                        "description": (
                            "Node path relative to the AnimationPlayer's root_node. "
                            "Use '.' to target the player's parent directly (the "
                            "default root_node setup)."
                        ),
                    },
                    "property": {
                        "type": "string",
                        "description": (
                            "Property name for 'value' tracks (required for that type, "
                            "ignored for others). Supports nested paths like "
                            "'modulate:a' for color alpha."
                        ),
                    },
                },
                "required": ["animation_path", "track_type", "node_path"],
            },
            "annotations": {
                "title": "Add Animation Track",
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "add_animation_keyframe",
            "description": (
                "Insert a keyframe into an Animation track at a given time. The "
                "expected value shape depends on the track's type (read from the "
                "Animation resource — the agent only sees track_index):\n\n"
                "  value         pass-through (number, string, color). Must match the "
                "underlying property's variant type.\n"
                "  position_3d   Vector3 from 'x,y,z' string, [x,y,z] array, or "
                "{x,y,z} dict.\n"
                "  rotation_3d   Quaternion. Accepts 'x,y,z' Euler degrees "
                "(matches set_node_transform's convention — auto-converted to "
                "Quaternion) or [x,y,z,w] Quaternion array.\n"
                "  scale_3d      Vector3, same parsing as position_3d.\n"
                "  method        Dictionary {method: name, args: [...]}.\n\n"
                "Returns key_index for the inserted key plus the updated key_count "
                "for the track. The .tres is saved on each keyframe insertion so the "
                "edits persist immediately."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "animation_path": {
                        "type": "string",
                        "description": "res:// path to the Animation .tres.",
                    },
                    "track_index": {
                        "type": "integer",
                        "description": "Index returned from add_animation_track.",
                    },
                    "time": {
                        "type": "number",
                        "description": "Seconds from animation start. Must be >= 0.",
                    },
                    "value": {
                        "description": (
                            "Keyframe value. Shape depends on the track's type (see "
                            "description). Bridge dispatches on the track type read "
                            "from the Animation resource."
                        ),
                    },
                    "transition": {
                        "type": "number",
                        "description": (
                            "Easing curve power for VALUE / METHOD tracks. Default "
                            "1.0 = linear. > 1 ease-out, between 0 and 1 ease-in. "
                            "Ignored for transform tracks (always linear blend)."
                        ),
                    },
                },
                "required": ["animation_path", "track_index", "time", "value"],
            },
            "annotations": {
                "title": "Add Animation Keyframe",
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_animation_properties",
            "description": (
                "Set top-level properties on an Animation .tres — length, loop_mode, "
                "and step. All args are optional but at least one must be present "
                "(empty calls are refused noisily to avoid the silent-no-op pattern). "
                "Call AFTER the keyframes are in place — a fresh Animation defaults to "
                "length=1.0s regardless of where your keys are, so a 0.6s jump "
                "animation whose last key is at 0.6s will pause 0.4s at the end "
                "during playback unless you set length=0.6 explicitly. The default "
                "loop_mode is also Animation-default, not user-specified — set it "
                "explicitly when the user requests looping or no-looping.\n\n"
                "  length     animation duration in seconds. Keys past `length` are "
                "preserved on disk but clipped during playback.\n"
                "  loop_mode  'none' (stops at end), 'linear' (loops "
                "start→end→start), or 'ping_pong' (forward then reverse). Also "
                "accepts 0/1/2 ints.\n"
                "  step       editor key-snap quantization (display only, does not "
                "affect playback). Default 1/30s. Must be > 0."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "animation_path": {
                        "type": "string",
                        "description": "res:// path to the Animation .tres.",
                    },
                    "length": {
                        "type": "number",
                        "description": "Animation duration in seconds. Must be >= 0.",
                    },
                    "loop_mode": {
                        "type": "string",
                        "description": "Loop mode: 'none' | 'linear' | 'ping_pong' (or 0 / 1 / 2).",
                    },
                    "step": {
                        "type": "number",
                        "description": "Editor key-snap quantization in seconds. Must be > 0.",
                    },
                },
                "required": ["animation_path"],
            },
            "annotations": {
                "title": "Set Animation Properties",
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": True,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_animation_player_info",
            "description": (
                "Read AnimationPlayer state — which libraries + animations are "
                "registered, current playback state (current_animation, autoplay, "
                "is_playing, speed_scale), and the player's top-level properties "
                "(root_node, playback_default_blend_time).\n\n"
                "Start here when extending or inspecting an existing animation setup "
                "— this returns the library + animation names you need to pass to "
                "add_animation_track / add_animation_keyframe / set_animation_properties. "
                "Do NOT use get_script_content to look up animations; .tres resources "
                "aren't GDScript.\n\n"
                "For per-Animation details (length, loop_mode, tracks, keys) the "
                "agent should load the .tres directly — those values live on the "
                "resource, not the player. Read-only: safe in play mode."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "player_path": {
                        "type": "string",
                        "description": "Scene-relative NodePath of an AnimationPlayer node.",
                    },
                },
                "required": ["player_path"],
            },
            "annotations": {
                "title": "Get Animation Player Info",
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
            },
        },
    },
]
