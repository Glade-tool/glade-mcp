"""
Godot scene/hierarchy tools — Node creation, lookup, transforms (11 tools).

Godot's scene model differs from Unity's GameObject+Component model:
each scene is a tree of Nodes (Node3D, CharacterBody3D, Sprite2D, ...);
"adding a component" means adding a child Node. Scripts attach to nodes
(at most one per node) via `attach_script_to_node` rather than via
`AddComponent<T>()`.

`node_path` accepts scene-relative paths ("Player/Sprite"), single names
(recursive find_child), absolute paths ("/root/Main/Player"), or empty
string / "." for the scene root.
"""

from typing import Dict, List

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "get_scene_tree",
            "description": (
                "Read the active scene's full node tree. Returns `node_count`, a flat "
                "indented `tree_text` listing every node (read this to enumerate the "
                "scene), and a nested `tree` of {name, type, path, children[], "
                "script_path?} for programmatic use. Safe to call any time (read-only, "
                "works in both edit and play mode). Call this first to understand what's "
                "in the scene before mutating it. To save context on large scenes, pass "
                "response_format='tree_text_only' — the ASCII view is enough for almost "
                "all reasoning, and dropping the nested JSON halves the response size."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "max_depth": {
                        "type": "integer",
                        "description": "Recursion cap against pathological scenes. Default 50.",
                    },
                    "response_format": {
                        "type": "string",
                        "description": (
                            "Which views to return. 'both' (default) returns tree + "
                            "tree_text. 'tree_text_only' drops the nested JSON tree "
                            "and is the token-efficient choice for agent reasoning. "
                            "'tree_only' drops the ASCII tree_text for programmatic callers."
                        ),
                        "enum": ["both", "tree_text_only", "tree_only"],
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_node_info",
            "description": (
                "Read metadata for a single node: name, class, attached script (if any), "
                "child count + names, groups, and (for Node3D/Node2D) transform. "
                "Use after find_nodes to inspect a specific match, or after create_node "
                "to confirm the result. Pass include_properties=true to also return a "
                "`properties` map of the node's settable scalar/vector/color/bool values "
                "— the exact set set_node_property can write — to discover what's "
                "configurable and read current values before setting."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "node_path": {
                        "type": "string",
                        "description": (
                            "Scene-relative path ('Player' or 'Player/Sprite'), absolute "
                            "('/root/Main/Player'), or empty/'.' for scene root."
                        ),
                    },
                    "include_properties": {
                        "type": "boolean",
                        "description": (
                            "When true, also return a `properties` map of settable "
                            "non-Resource property values (what set_node_property writes). "
                            "Default false."
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
            "name": "find_nodes",
            "description": (
                "Search the edited scene by name, type, or group. Filters are AND-combined. "
                "Returns scene-relative paths plus a truncated flag if max_results was hit. "
                "Use type='CharacterBody3D' or type='Light3D' for class-based queries — "
                "this is Godot's idiom for what Unity does with tags/layers."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "name_contains": {
                        "type": "string",
                        "description": "Case-insensitive substring match on node name.",
                    },
                    "name_exact": {
                        "type": "string",
                        "description": "Exact node-name match.",
                    },
                    "type": {
                        "type": "string",
                        "description": (
                            "Godot class name. Matches subclasses too — type='Node3D' picks up "
                            "MeshInstance3D, CharacterBody3D, etc."
                        ),
                    },
                    "group": {
                        "type": "string",
                        "description": "Node must be in this Godot group.",
                    },
                    "max_results": {
                        "type": "integer",
                        "description": "Default 100, clamped 1..500.",
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_node",
            "description": (
                "Instantiate a new Node of the requested Godot class and add it to the "
                "edited scene. The `type` arg is any instantiable ClassDB class name OR "
                "a user-declared `class_name` from a project script. Sets owner=scene_root "
                "so the new node persists when the scene is saved. For mesh primitives use "
                "create_primitive_3d instead — it bundles a MeshInstance3D + PrimitiveMesh. "
                "For UI nodes (Control subclasses — Button, Label, Panel, containers, "
                "popup dialogs) use create_control instead — it handles CanvasLayer auto-wrap "
                "and accepts inline text + anchor_preset args."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "type": {
                        "type": "string",
                        "description": (
                            "Godot class name: Node3D, CharacterBody3D, Sprite2D, RigidBody3D, "
                            "MeshInstance3D, etc. User `class_name` declarations also resolve."
                        ),
                    },
                    "name": {
                        "type": "string",
                        "description": "Name for the new node. Defaults to the type name.",
                    },
                    "parent_path": {
                        "type": "string",
                        "description": "Scene-relative parent path. Defaults to scene root.",
                    },
                },
                "required": ["type"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_primitive_3d",
            "description": (
                "Convenience: create a MeshInstance3D with a built-in PrimitiveMesh "
                "(BoxMesh / SphereMesh / ...) in one call. Use for visible scene geometry "
                "(player capsules, platforms, props). For physics-collidable bodies use "
                "create_physics_body — it auto-attaches a CollisionShape3D."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "primitive": {
                        "type": "string",
                        "description": "Mesh type.",
                        "enum": ["box", "sphere", "cylinder", "capsule", "plane", "prism", "torus", "quad"],
                    },
                    "name": {
                        "type": "string",
                        "description": "Node name. Defaults to capitalized primitive name.",
                    },
                    "parent_path": {
                        "type": "string",
                        "description": "Scene-relative parent path. Defaults to scene root.",
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "delete_node",
            "description": (
                "Remove a node and its full subtree from the edited scene. "
                "Refuses to delete the scene root — close/replace the scene instead."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "node_path": {
                        "type": "string",
                        "description": "Scene-relative path of the node to delete.",
                    },
                },
                "required": ["node_path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "rename_node",
            "description": (
                "Rename an existing node. Godot auto-uniquifies names within a parent — "
                "if the requested name collides, the response echoes the actual final name."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "node_path": {
                        "type": "string",
                        "description": "Scene-relative path of the target node.",
                    },
                    "new_name": {
                        "type": "string",
                        "description": "Desired new name (must be non-empty).",
                    },
                },
                "required": ["node_path", "new_name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "duplicate_node",
            "description": (
                "Duplicate a node (and its full subtree) under the same parent. "
                "Scripts and resources are duplicated by reference (Godot's default)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "node_path": {
                        "type": "string",
                        "description": "Scene-relative path of the source node.",
                    },
                    "new_name": {
                        "type": "string",
                        "description": "Name for the duplicate. If omitted Godot picks '<name>2', '<name>3', ...",
                    },
                },
                "required": ["node_path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_node_parent",
            "description": (
                "Move a node under a new parent within the edited scene. "
                "Default keep_transform=true preserves the node's global transform "
                "(meaningful for Node3D/Node2D)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "node_path": {
                        "type": "string",
                        "description": "Node to move.",
                    },
                    "new_parent_path": {
                        "type": "string",
                        "description": "Destination parent (empty/'.' = scene root).",
                    },
                    "keep_transform": {
                        "type": "boolean",
                        "description": "Preserve global transform across the move. Default true.",
                    },
                },
                "required": ["node_path", "new_parent_path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_node_transform",
            "description": (
                "Set position, rotation (Euler degrees), and/or scale on a Node3D or "
                "Node2D. Each component is independent — omit args to leave them unchanged. "
                "Use operation='add' for relative moves, 'multiply' for relative scales."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "node_path": {"type": "string", "description": "Target node path."},
                    "space": {
                        "type": "string",
                        "description": "Coordinate space. Default 'local'.",
                        "enum": ["local", "global"],
                    },
                    "position": {
                        "type": "string",
                        "description": "Vector as 'x,y,z' (or 'x,y' for Node2D).",
                    },
                    "rotation": {
                        "type": "string",
                        "description": "Euler degrees as 'x,y,z' (Node3D) or scalar (Node2D).",
                    },
                    "scale": {
                        "type": "string",
                        "description": "Scale vector as 'x,y,z'.",
                    },
                    "operation": {
                        "type": "string",
                        "description": "Per-component op. Default 'set'.",
                        "enum": ["set", "add", "multiply"],
                    },
                },
                "required": ["node_path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_node_resource",
            "description": (
                "Assign a Resource loaded from a res:// path to a Resource-typed "
                "property on a node — e.g. a Mesh onto MeshInstance3D.mesh, a "
                "Texture2D onto Sprite2D.texture, a Shape3D onto "
                "CollisionShape3D.shape, an AudioStream onto AudioStreamPlayer.stream, "
                "an Environment onto Camera3D.environment, or a Material onto "
                "material_override. One tool for every 'give this node a resource' "
                'case. Pass resource_path="" (or null) to clear the property.\n\n'
                "Validates that the property exists and is resource-typed; when the "
                "property declares a built-in expected class, the loaded resource "
                "must match it (the error lists the node's resource-typed properties "
                "to recover from a wrong name).\n\n"
                "For MeshInstance3D per-surface material overrides, use "
                "set_material_property (target_node_path + surface) instead."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "node_path": {
                        "type": "string",
                        "description": "Target node in the edited scene.",
                    },
                    "property": {
                        "type": "string",
                        "description": (
                            "Resource-typed property to set, e.g. 'mesh', 'texture', "
                            "'shape', 'stream', 'material_override', 'environment'."
                        ),
                    },
                    "resource_path": {
                        "type": "string",
                        "description": (
                            'res:// path to the resource to load and assign. Pass "" or null to clear the property.'
                        ),
                    },
                },
                "required": ["node_path", "property", "resource_path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_node_property",
            "description": (
                "Set a single non-Resource property to a literal value on any node — "
                "the generic companion to the specialized setters. Where "
                "set_node_transform owns position/rotation/scale and set_node_resource "
                "owns Resource-typed properties (mesh, texture, stream, ...), this tool "
                "covers everything else: scalars, vectors, colors, booleans, and enums. "
                "Pairs with create_node to create-then-configure any node. Examples:\n"
                "  AudioStreamPlayer.volume_db / .autoplay / .pitch_scale\n"
                "  Camera3D.fov / .current / .cull_mask\n"
                "  GPUParticles3D.amount / .lifetime / .emitting / .one_shot\n"
                "  RigidBody3D.mass / .gravity_scale / .freeze\n"
                "  Light3D.light_energy, Label.text, ...\n\n"
                "The value is coerced to the property's declared type: numbers, bools, "
                "and strings pass through; 'x,y,z' / [x,y,z] become Vector2/Vector3; "
                "'#rrggbb' / [r,g,b,a] become Color; an enum label like "
                "'PROCESS_MODE_ALWAYS' resolves to its int. Unknown property names "
                "return the node's settable properties + the nearest match. To read "
                "current values first, call get_node_info with include_properties=true. "
                "For Resource-typed properties, use set_node_resource instead."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "node_path": {
                        "type": "string",
                        "description": "Target node in the edited scene.",
                    },
                    "property": {
                        "type": "string",
                        "description": (
                            "Property name as Godot exposes it (snake_case), "
                            "e.g. 'volume_db', 'fov', 'mass', 'emitting'."
                        ),
                    },
                    "value": {
                        "description": (
                            "New value. Number/bool/string pass through; 'x,y,z' or "
                            "[x,y,z] become a vector; '#rrggbb' or [r,g,b,a] become a "
                            "color; an enum label resolves to its int."
                        ),
                    },
                },
                "required": ["node_path", "property", "value"],
            },
        },
    },
]
