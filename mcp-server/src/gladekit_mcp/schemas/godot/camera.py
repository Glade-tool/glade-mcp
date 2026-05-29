"""
Godot camera + light tools (2 tools).

`create_light` covers DirectionalLight3D, OmniLight3D, and SpotLight3D
behind a single `type` arg — the original three-tool plan was deduped
to one tool with a type parameter, matching the way Godot users actually
reason about lights.
"""

from typing import Dict, List

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "create_camera_3d",
            "description": (
                "Create a Camera3D node and add it to the edited scene. Optionally "
                "orient toward a target via look_at, and/or make it the active camera "
                "via current=true. For 2D scenes use create_node with type='Camera2D'."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Node name. Default 'Camera3D'."},
                    "parent_path": {
                        "type": "string",
                        "description": "Scene-relative parent. Default scene root.",
                    },
                    "current": {
                        "type": "boolean",
                        "description": "Make this the active camera. Default false.",
                    },
                    "fov": {
                        "type": "number",
                        "description": "Field of view in degrees. Default 75.",
                    },
                    "position": {
                        "type": "string",
                        "description": "Initial position as 'x,y,z'. Default '0,0,5'.",
                    },
                    "look_at": {
                        "type": "string",
                        "description": (
                            "Optional point to orient toward, as 'x,y,z'. The camera will be rotated automatically."
                        ),
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_light",
            "description": (
                "Create a Light3D node (DirectionalLight3D / OmniLight3D / SpotLight3D). "
                "The `type` arg picks the subclass — 'directional' for sun-style lighting, "
                "'omni' for point lights, 'spot' for cone lights. Directional lights get "
                "a sensible 45° default rotation if no rotation is passed."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "type": {
                        "type": "string",
                        "description": "Light kind.",
                        "enum": ["directional", "omni", "spot"],
                    },
                    "name": {
                        "type": "string",
                        "description": "Node name. Defaults to the Godot class (e.g. 'DirectionalLight3D').",
                    },
                    "parent_path": {
                        "type": "string",
                        "description": "Scene-relative parent. Default scene root.",
                    },
                    "energy": {
                        "type": "number",
                        "description": "Light energy multiplier. Default 1.0.",
                    },
                    "color": {
                        "type": "string",
                        "description": "Hex '#rrggbb' or comma-separated 'r,g,b' (0-1). Default white.",
                    },
                    "position": {
                        "type": "string",
                        "description": "Initial position as 'x,y,z'. Default '0,3,0'.",
                    },
                    "shadow": {
                        "type": "boolean",
                        "description": "Enable shadow casting. Default true.",
                    },
                },
                "required": ["type"],
            },
        },
    },
]
