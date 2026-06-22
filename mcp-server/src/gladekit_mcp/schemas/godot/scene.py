"""
Godot scene/hierarchy tools — Node creation, lookup, transforms (18 tools).

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
                "in the scene before mutating it. Also returns `root_space` ('2d' | '3d' "
                "| 'ui' | 'other'), the workspace the scene root lives in — use it to pick "
                "2D vs 3D node types (a Node2D root means add Sprite2D / Camera2D, not "
                "MeshInstance3D / Camera3D). To save context on large scenes, pass "
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
            "name": "create_sprite_2d",
            "description": (
                "Convenience: create a Sprite2D and assign its texture in one call — the "
                "2D analogue of create_primitive_3d. Use for static 2D images (player, "
                "props, backgrounds). Pass a res:// `texture` path (a sprite with no "
                "texture is invisible). For frame-based animation use "
                "create_animated_sprite_2d instead. Spritesheets: set hframes/vframes and "
                "pick a `frame`."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "texture": {
                        "type": "string",
                        "description": "res:// path to the image (png/webp/svg/…). Strongly recommended.",
                    },
                    "name": {
                        "type": "string",
                        "description": "Node name. Defaults to the texture filename, else 'Sprite2D'.",
                    },
                    "parent_path": {
                        "type": "string",
                        "description": "Scene-relative parent path. Defaults to scene root.",
                    },
                    "position": {
                        "type": "string",
                        "description": "Initial position in pixels, 'x,y'. Default '0,0'.",
                    },
                    "centered": {
                        "type": "boolean",
                        "description": "Centre the texture on the node origin. Default true.",
                    },
                    "modulate": {
                        "type": "string",
                        "description": "Tint color, '#rrggbb[aa]' or 'r,g,b[,a]'. Default white.",
                    },
                    "hframes": {
                        "type": "integer",
                        "description": "Horizontal frames for a spritesheet. Default 1.",
                    },
                    "vframes": {
                        "type": "integer",
                        "description": "Vertical frames for a spritesheet. Default 1.",
                    },
                    "frame": {
                        "type": "integer",
                        "description": "Which frame to show (0-based) when h/vframes > 1.",
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_animated_sprite_2d",
            "description": (
                "Create an AnimatedSprite2D with a ready-to-play SpriteFrames — the "
                "frame-based 2D animation workflow (run cycles, coin spins, explosions). "
                "Bundles node + SpriteFrames + frames in one call (an AnimatedSprite2D "
                "with no SpriteFrames shows nothing); the SpriteFrames is embedded in the "
                "scene. Supply frames EITHER as `frames` (a list of individual res:// "
                "texture paths) OR as `spritesheet` (one image sliced into a grid by "
                "hframes/vframes) — use the spritesheet form when you have a single strip/"
                "grid image like run.png. If both are given, the spritesheet wins."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "frames": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "res:// texture paths, one per animation frame, in order.",
                    },
                    "spritesheet": {
                        "type": "string",
                        "description": (
                            "res:// path to a grid spritesheet, sliced into frames via hframes/vframes (row-major)."
                        ),
                    },
                    "hframes": {
                        "type": "integer",
                        "description": "Spritesheet columns (with `spritesheet`). Default 1.",
                    },
                    "vframes": {
                        "type": "integer",
                        "description": "Spritesheet rows (with `spritesheet`). Default 1.",
                    },
                    "frame_start": {
                        "type": "integer",
                        "description": "First grid cell (0-based, row-major) to include. Default 0.",
                    },
                    "frame_end": {
                        "type": "integer",
                        "description": "Last grid cell to include. Default: last cell.",
                    },
                    "animation": {
                        "type": "string",
                        "description": "Animation name. Default 'default'.",
                    },
                    "fps": {
                        "type": "number",
                        "description": "Playback speed in frames/sec. Default 10.",
                    },
                    "loop": {
                        "type": "boolean",
                        "description": "Loop the animation. Default true.",
                    },
                    "autoplay": {
                        "type": "boolean",
                        "description": "Start this animation automatically at runtime. Default false.",
                    },
                    "name": {
                        "type": "string",
                        "description": "Node name. Default 'AnimatedSprite2D'.",
                    },
                    "parent_path": {
                        "type": "string",
                        "description": "Scene-relative parent path. Defaults to scene root.",
                    },
                    "position": {
                        "type": "string",
                        "description": "Initial position in pixels, 'x,y'. Default '0,0'.",
                    },
                    "centered": {
                        "type": "boolean",
                        "description": "Centre frames on the node origin. Default true.",
                    },
                    "modulate": {
                        "type": "string",
                        "description": "Tint color, '#rrggbb[aa]' or 'r,g,b[,a]'. Default white.",
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_tilemap_layer",
            "description": (
                "Create a TileMapLayer (Godot 4.3+; replaced TileMap) with a ready-to-paint "
                "TileSet scaffolded from a tile atlas image — the foundation for tile-based "
                "2D levels (platformers, top-down RPGs). Pass `texture` (a tile atlas) and "
                "`tile_size`; the tool slices the atlas into tiles so the very next "
                "set_tilemap_cells call can paint them. Without a texture you get an empty, "
                "unpaintable layer."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "texture": {
                        "type": "string",
                        "description": "res:// tile atlas image. Strongly recommended (no texture = no tiles).",
                    },
                    "tile_size": {
                        "type": "string",
                        "description": "Tile size in pixels, 'x,y'. Default '16,16'. Also the atlas slice size.",
                    },
                    "name": {"type": "string", "description": "Node name. Default 'TileMapLayer'."},
                    "parent_path": {
                        "type": "string",
                        "description": "Scene-relative parent path. Defaults to scene root.",
                    },
                    "position": {
                        "type": "string",
                        "description": "Initial position in pixels, 'x,y'. Default '0,0'.",
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_tilemap_cells",
            "description": (
                "Paint or erase cells on an existing TileMapLayer (pairs with "
                "create_tilemap_layer). Specify cells individually via `cells` and/or fill "
                "a rectangular region via `fill_rect`. Each cell coordinate is in tile "
                "units, not pixels. `atlas` picks which tile from the atlas to stamp "
                "(default '0,0'). Set erase=true to clear cells instead of painting."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "node_path": {
                        "type": "string",
                        "description": "Scene-relative path to the TileMapLayer.",
                    },
                    "source_id": {
                        "type": "integer",
                        "description": "TileSet atlas source id. Default: the layer's first source.",
                    },
                    "atlas": {
                        "type": "string",
                        "description": "Default atlas tile coords 'ax,ay' for cells that don't specify. Default '0,0'.",
                    },
                    "cells": {
                        "type": "array",
                        "description": (
                            "Cells to set. Each entry is [x,y] (uses default atlas), "
                            "[x,y,atlas_x,atlas_y], or {x,y,atlas_x?,atlas_y?}. Coords are tile units."
                        ),
                        "items": {},
                    },
                    "fill_rect": {
                        "type": "string",
                        "description": "Fill a w×h block of cells with the default atlas tile, as 'x,y,w,h' (tile units).",
                    },
                    "erase": {
                        "type": "boolean",
                        "description": "Clear the listed cells / rect instead of painting. Default false.",
                    },
                },
                "required": ["node_path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_tilemap_collision",
            "description": (
                "Make a TileMapLayer's tiles SOLID so a CharacterBody2D can stand on them. "
                "A painted TileMapLayer is purely visual until this runs — without it a "
                "player (e.g. from create_2d_controller) falls straight through the floor. "
                "Adds a physics layer to the TileSet and a full-tile rectangle collision "
                "polygon to every atlas tile. Pass one_way=true for pass-through platformer "
                "floors (land on top, jump up through from below). Call this once after "
                "building a tile level (create_tilemap_layer + set_tilemap_cells), then save_scene."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "tilemap_path": {
                        "type": "string",
                        "description": "Scene-relative path to the TileMapLayer to make solid.",
                    },
                    "collision_layer": {
                        "type": "integer",
                        "description": "Physics layer bitmask the tiles occupy. Default 1.",
                    },
                    "collision_mask": {
                        "type": "integer",
                        "description": "Physics layers the tiles scan. Default 1.",
                    },
                    "physics_layer": {
                        "type": "integer",
                        "description": ("TileSet physics-layer index to author (created if absent). Default 0."),
                    },
                    "clear_existing": {
                        "type": "boolean",
                        "description": (
                            "Remove existing collision polygons on each tile first so re-running "
                            "doesn't stack duplicates. Default true."
                        ),
                    },
                    "one_way": {
                        "type": "boolean",
                        "description": (
                            "Make the tiles ONE-WAY platforms: a body lands on top but jumps up "
                            "through from below. The classic pass-through floor. Default false."
                        ),
                    },
                    "one_way_margin": {
                        "type": "number",
                        "description": "Thickness (px) of the one-way detection band. Default 1.0. Only used when one_way is true.",
                    },
                },
                "required": ["tilemap_path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_parallax_2d",
            "description": (
                "Create a Parallax2D (Godot 4.3+; replaced ParallaxBackground/ParallaxLayer) "
                "for depth-scrolling 2D backgrounds. scroll_scale below 1 makes the layer "
                "move slower than the camera (distant-background effect). Pass `texture` to "
                "drop in a Sprite2D child; repeat_size defaults to the texture size so it "
                "tiles seamlessly as the camera moves."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "scroll_scale": {
                        "type": "string",
                        "description": "Scroll speed vs camera. A number (uniform) or 'x,y'. <1 = slower/further. Default 0.5.",
                    },
                    "texture": {
                        "type": "string",
                        "description": "res:// background image. Optional; adds a Sprite2D child when given.",
                    },
                    "repeat_size": {
                        "type": "string",
                        "description": "Tiling period in pixels 'x,y'. Default: the texture size (seamless tiling).",
                    },
                    "name": {"type": "string", "description": "Node name. Default 'Parallax2D'."},
                    "parent_path": {
                        "type": "string",
                        "description": "Scene-relative parent path. Defaults to scene root.",
                    },
                    "position": {
                        "type": "string",
                        "description": "Initial position in pixels, 'x,y'. Default '0,0'.",
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_moving_platform",
            "description": (
                "Build a moving platform (or send an existing node patrolling a route) in one "
                "call: a Path2D waypoint curve, a PathFollow2D that travels it at constant speed, "
                "and a rider. The default rider is a scaffolded AnimatableBody2D platform that "
                "CARRIES a CharacterBody2D player (a StaticBody2D would not); pass target_path to "
                "send an existing node along instead, leaving its script intact. Writes a vetted "
                "mover script once (reused across calls). 2D-only. loop_mode: loop / pingpong / once."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "points": {
                        "type": "string",
                        "description": (
                            "Route waypoints relative to position, as a 'x,y;x,y;...' string or a JSON "
                            "array like [[0,0],[200,0]]. First point is the start. Default '0,0;200,0'."
                        ),
                    },
                    "speed": {
                        "type": "number",
                        "description": "Pixels per second along the curve. Default 80.",
                    },
                    "loop_mode": {
                        "type": "string",
                        "enum": ["loop", "pingpong", "once"],
                        "description": "loop = wrap around, pingpong = back and forth, once = travel then stop. Default loop.",
                    },
                    "wait_time": {
                        "type": "number",
                        "description": "Seconds to pause at each end (pingpong/once). Default 0.",
                    },
                    "size": {
                        "type": "string",
                        "description": "Scaffolded platform size 'w,h' in pixels. Default '96,16'. Ignored when target_path is set.",
                    },
                    "one_way": {
                        "type": "boolean",
                        "description": "Make the scaffolded platform one-way (land on top, jump up through from below). Default false. Ignored when target_path is set.",
                    },
                    "color": {
                        "type": "string",
                        "description": "Placeholder fill color for the scaffolded platform (hex or 'r,g,b').",
                    },
                    "target_path": {
                        "type": "string",
                        "description": "Scene-relative path to an existing Node2D to send along the route instead of scaffolding a platform.",
                    },
                    "name": {"type": "string", "description": "Path2D node name. Default 'MovingPlatform'."},
                    "parent_path": {
                        "type": "string",
                        "description": "Scene-relative parent path. Defaults to scene root.",
                    },
                    "position": {
                        "type": "string",
                        "description": "Path2D placement in pixels 'x,y' (waypoints are relative to it). Default '0,0'.",
                    },
                    "directory": {
                        "type": "string",
                        "description": "res:// folder for the generated mover script. Default 'res://scripts'.",
                    },
                    "overwrite": {
                        "type": "boolean",
                        "description": "Regenerate the shared mover script if it exists. Default false.",
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
