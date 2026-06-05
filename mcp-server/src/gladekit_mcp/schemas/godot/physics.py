"""
Godot physics tools (1 tool).

Godot's physics body classes are nodes: StaticBody{3D,2D}, RigidBody{3D,2D},
CharacterBody{3D,2D}. A body without a CollisionShape child does nothing,
so `create_physics_body` bundles the body + a shape in one call via
`auto_shape=true` (default). The original add_collision_shape tool was
folded into this — Godot devs almost always want a body with a shape,
and forcing two calls is friction. The `space` arg ("3d" default / "2d")
picks the dimension, so the same tool builds 3D props and 2D platformer
bodies alike.
"""

from typing import Dict, List

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "create_physics_body",
            "description": (
                "Create a physics body (StaticBody / RigidBody / CharacterBody) in 3D "
                "or 2D with an optional CollisionShape child. Set space='2d' for "
                "platformer/top-down bodies (CharacterBody2D etc.), or omit for 3D "
                "(default). Default auto_shape=true bundles the body + shape; pass "
                "auto_shape=false to skip and add shapes manually. For player "
                "controllers use body_type='character'; for level geometry use 'static'; "
                "for dynamic physics-simulated objects use 'rigid'. This is the Godot "
                "idiom — Unity's CharacterController equivalent."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "space": {
                        "type": "string",
                        "description": (
                            "Dimension: '3d' (default, Node3D bodies) or '2d' "
                            "(Node2D bodies for platformers/top-down games)."
                        ),
                        "enum": ["3d", "2d"],
                    },
                    "body_type": {
                        "type": "string",
                        "description": "Physics body kind.",
                        "enum": ["static", "rigid", "character"],
                    },
                    "name": {
                        "type": "string",
                        "description": "Node name. Defaults to the Godot class name.",
                    },
                    "parent_path": {
                        "type": "string",
                        "description": "Scene-relative parent. Default scene root.",
                    },
                    "position": {
                        "type": "string",
                        "description": "Initial position — 'x,y,z' (3D) or 'x,y' (2D). Default 0.",
                    },
                    "auto_shape": {
                        "type": "boolean",
                        "description": "Add a CollisionShape child with a default shape. Default true.",
                    },
                    "shape_type": {
                        "type": "string",
                        "description": (
                            "Shape kind when auto_shape=true. 3D: box/sphere/capsule/"
                            "cylinder. 2D: box (rect)/circle/capsule."
                        ),
                        "enum": ["box", "sphere", "circle", "capsule", "cylinder"],
                    },
                    "shape_size": {
                        "type": "string",
                        "description": (
                            "Shape sizing. 3D 'x,y,z' — box: extents; sphere/capsule: "
                            "x=radius, y=height (default '1,1,1', metres). 2D 'x,y' — "
                            "rect: size; circle/capsule: x=radius, y=height "
                            "(default '32,32', pixels)."
                        ),
                    },
                    "mass": {
                        "type": "number",
                        "description": "Mass (RigidBody3D/2D only). Default 1.0.",
                    },
                },
                "required": ["body_type"],
            },
        },
    },
]
