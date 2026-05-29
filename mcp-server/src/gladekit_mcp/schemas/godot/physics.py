"""
Godot physics tools (1 tool).

Godot's physics body classes are nodes: StaticBody3D, RigidBody3D,
CharacterBody3D. A body without a CollisionShape3D child does nothing,
so `create_physics_body` bundles the body + a shape in one call via
`auto_shape=true` (default). The original add_collision_shape tool was
folded into this — Godot devs almost always want a body with a shape,
and forcing two calls is friction.
"""

from typing import Dict, List

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "create_physics_body",
            "description": (
                "Create a PhysicsBody3D (StaticBody3D / RigidBody3D / CharacterBody3D) "
                "with an optional CollisionShape3D child. Default auto_shape=true bundles "
                "the body + shape; pass auto_shape=false to skip and add shapes manually. "
                "For player controllers use body_type='character'; for level geometry "
                "use 'static'; for dynamic physics-simulated objects use 'rigid'. "
                "This is the Godot idiom — Unity's CharacterController equivalent."
            ),
            "parameters": {
                "type": "object",
                "properties": {
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
                        "description": "Initial position as 'x,y,z'. Default '0,0,0'.",
                    },
                    "auto_shape": {
                        "type": "boolean",
                        "description": "Add a CollisionShape3D child with a default shape. Default true.",
                    },
                    "shape_type": {
                        "type": "string",
                        "description": "Shape kind when auto_shape=true.",
                        "enum": ["box", "sphere", "capsule", "cylinder"],
                    },
                    "shape_size": {
                        "type": "string",
                        "description": (
                            "Shape sizing as 'x,y,z'. Box: extents. Sphere/capsule: "
                            "x=radius, y=height. Default '1,1,1'."
                        ),
                    },
                    "mass": {
                        "type": "number",
                        "description": "Mass (RigidBody3D only). Default 1.0.",
                    },
                },
                "required": ["body_type"],
            },
        },
    },
]
