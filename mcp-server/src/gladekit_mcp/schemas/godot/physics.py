"""
Godot physics tools (3 tools).

Godot's physics body classes are nodes: StaticBody{3D,2D}, RigidBody{3D,2D},
CharacterBody{3D,2D}. A body without a CollisionShape child does nothing,
so `create_physics_body` bundles the body + a shape in one call via
`auto_shape=true` (default). The original add_collision_shape tool was
folded into this — Godot devs almost always want a body with a shape,
and forcing two calls is friction. The `space` arg ("3d" default / "2d")
picks the dimension, so the same tool builds 3D props and 2D platformer
bodies alike.

`raycast` is the spatial-query counterpart: cast a ray through the scene's
physics space and report the first collider hit. It runs against the open
scene at edit time (no play session needed), so an agent can answer "what's
under this point", "is there a wall between A and B", or "what would a shot
from here hit" while building the scene.

`overlap_shape` is the volume query (a ray is a line; this is a region):
find every collider overlapping a sphere/box at a point — "which enemies
are within blast radius", "is this spot clear before placing something",
"what's inside this zone". Also edit-time.
"""

from typing import Dict, List

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "create_physics_body",
            "description": (
                "Create a collision object (StaticBody / RigidBody / CharacterBody / Area) "
                "in 3D or 2D with an optional CollisionShape child. `space` is inferred "
                "from the open scene's root when omitted (2D scene → Node2D bodies), or "
                "pass it explicitly. Default auto_shape=true bundles the body + shape; pass "
                "auto_shape=false to skip. body_type: 'character' for player controllers, "
                "'static' for level geometry, 'rigid' for dynamic physics objects, 'area' "
                "for trigger/sensor zones (Area2D/Area3D — pickups, hurtboxes, checkpoints, "
                "no collision response). This is the Godot idiom — Unity's "
                "CharacterController equivalent."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "space": {
                        "type": "string",
                        "description": (
                            "Dimension: '2d' (Node2D bodies for platformers/top-down) or "
                            "'3d' (Node3D bodies). Inferred from the open scene's root "
                            "when omitted (falls back to 3d)."
                        ),
                        "enum": ["3d", "2d"],
                    },
                    "body_type": {
                        "type": "string",
                        "description": "Collision-object kind ('area' = trigger/sensor zone).",
                        "enum": ["static", "rigid", "character", "area"],
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
    {
        "type": "function",
        "function": {
            "name": "raycast",
            "description": (
                "Cast a ray through the scene's physics space and return the FIRST "
                "collider it hits — the spatial-query primitive for 'what's under this "
                "point', 'is there a wall between A and B', 'what would a shot from here "
                "hit'. Runs at EDIT time against the open scene (no play session): the "
                "scene's collision bodies are live in the editor's physics space. "
                "Dimension is inferred from the open scene (2D vs 3D). Aim the ray with "
                "from+to, or from+direction(+distance, default 1000). Only colliders "
                "whose layer intersects collision_mask are hit (default: all layers). "
                "Pass exclude (node paths) to ignore colliders — e.g. the caster itself "
                "so it doesn't self-hit. Returns hit (bool) and, when hit, the collider "
                "node path/name/class, world position, surface normal, and distance."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "from": {
                        "type": "string",
                        "description": "Ray origin — 'x,y,z' (3D) or 'x,y' (2D).",
                    },
                    "to": {
                        "type": "string",
                        "description": "Ray end point. Omit to use direction + distance.",
                    },
                    "direction": {
                        "type": "string",
                        "description": "Ray direction (normalized internally). Used when `to` is omitted.",
                    },
                    "distance": {
                        "type": "number",
                        "description": "Ray length when using direction. Default 1000.",
                    },
                    "collision_mask": {
                        "type": "integer",
                        "description": "Layer bitmask to test against. Default all layers.",
                    },
                    "collide_with_bodies": {
                        "type": "boolean",
                        "description": "Hit PhysicsBodies. Default true.",
                    },
                    "collide_with_areas": {
                        "type": "boolean",
                        "description": "Hit Areas (triggers). Default false.",
                    },
                    "hit_from_inside": {
                        "type": "boolean",
                        "description": "Register a hit when `from` starts inside a shape. Default false.",
                    },
                    "exclude": {
                        "type": "array",
                        "description": "Node paths whose colliders are ignored (e.g. the caster).",
                        "items": {"type": "string"},
                    },
                },
                "required": ["from"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "overlap_shape",
            "description": (
                "Find EVERY collider overlapping a shape placed at a point — the volume "
                "counterpart of raycast (a ray is a line; this is a region). Use for "
                "'which enemies are within blast radius', 'is this spot clear before I "
                "place something', 'what's inside this zone'. Runs at EDIT time against "
                "the open scene (no play session). Dimension is inferred from the open "
                "scene (2D vs 3D). shape is 'sphere'/'box' (3D) or 'circle'/'box' (2D); "
                "sphere/circle uses `radius`, box uses `size` (full extents). Only "
                "colliders whose layer intersects collision_mask match (default: all). "
                "Pass exclude (node paths) to skip colliders — e.g. the node the query "
                "is centred on. Returns count + colliders (each node once, de-duplicated) "
                "with path/name/class, and a truncated flag if max_results was hit."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "position": {
                        "type": "string",
                        "description": "Query centre — 'x,y,z' (3D) or 'x,y' (2D).",
                    },
                    "shape": {
                        "type": "string",
                        "description": "Query shape. Default sphere (3D) / circle (2D).",
                        "enum": ["sphere", "circle", "box"],
                    },
                    "radius": {
                        "type": "number",
                        "description": "Sphere/circle radius. Default 1.0 (3D) / 32 (2D).",
                    },
                    "size": {
                        "type": "string",
                        "description": "Box full size — 'x,y,z' (3D) or 'x,y' (2D). Default 1,1,1 / 32,32.",
                    },
                    "collision_mask": {
                        "type": "integer",
                        "description": "Layer bitmask to test against. Default all layers.",
                    },
                    "collide_with_bodies": {
                        "type": "boolean",
                        "description": "Match PhysicsBodies. Default true.",
                    },
                    "collide_with_areas": {
                        "type": "boolean",
                        "description": "Match Areas (triggers). Default false.",
                    },
                    "exclude": {
                        "type": "array",
                        "description": "Node paths whose colliders are ignored.",
                        "items": {"type": "string"},
                    },
                    "max_results": {
                        "type": "integer",
                        "description": "Cap on colliders returned. Default 32 (clamped 1..1024).",
                    },
                },
                "required": ["position"],
            },
        },
    },
]
