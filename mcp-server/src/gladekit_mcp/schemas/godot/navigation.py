"""
Godot 3D navigation / pathfinding tools (2 tools).

`bake_navigation_mesh` makes a 3D scene walkable: it finds-or-creates a
NavigationRegion3D, configures a NavigationMesh (cell size + agent
dimensions), sources the scene's geometry via a group (non-destructive —
nothing is reparented), and bakes synchronously. `add_navigation_agent`
drops a configured NavigationAgent3D on a body so it can path across that
region.

Both are 3D-only (Node3D family) and refuse on a 2D scene root, mirroring
the dimension guard on create_enemy_3d. The agent computes paths but does
not move the body by itself — add_navigation_agent's response carries a
GDScript movement-loop snippet, and create_enemy_3d is the vetted mover.
"""

from typing import Dict, List

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "bake_navigation_mesh",
            "description": (
                "Make a 3D scene walkable so agents can pathfind: finds or creates a "
                "NavigationRegion3D, configures a NavigationMesh, sources the scene's "
                "geometry, and bakes it. Call this before add_navigation_agent — an "
                "agent can only path across a region with a baked mesh. Sources "
                "geometry non-destructively via a group, so your level does NOT need "
                "to be parented under the region; floors made with create_physics_body "
                "(static body + collider, no visible mesh) bake too. 3D-only: refuses "
                "on a 2D scene. If the bake returns 0 polygons, the area has no "
                "walkable floor — add one (create_primitive_3d plane / "
                "create_physics_body static) and bake again."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "region_path": {
                        "type": "string",
                        "description": (
                            "Scene-relative path to an existing NavigationRegion3D to "
                            "re-bake. Omit to reuse the first region in the scene or "
                            "create a new one."
                        ),
                    },
                    "region_name": {
                        "type": "string",
                        "description": "Name for a newly created region. Default 'NavigationRegion3D'.",
                    },
                    "parent_path": {
                        "type": "string",
                        "description": "Scene-relative parent for a new region. Default scene root.",
                    },
                    "source_path": {
                        "type": "string",
                        "description": (
                            "Scene-relative node whose geometry (and its children's) is the "
                            "walkable area. Default: the whole scene, which is right for most "
                            "'make my level walkable' requests."
                        ),
                    },
                    "cell_size": {
                        "type": "number",
                        "description": "Navmesh voxel size in metres. Smaller = more precise, slower. Default 0.25.",
                    },
                    "agent_radius": {
                        "type": "number",
                        "description": "Walkable area is shrunk this far from walls so an agent of this radius fits. Default 0.5.",
                    },
                    "agent_height": {
                        "type": "number",
                        "description": "Minimum ceiling clearance in metres. Default 1.5.",
                    },
                    "agent_max_climb": {
                        "type": "number",
                        "description": "Tallest step an agent can walk up, in metres. Default 0.25.",
                    },
                    "agent_max_slope": {
                        "type": "number",
                        "description": "Steepest walkable incline in degrees. Default 45.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "add_navigation_agent",
            "description": (
                "Add a NavigationAgent3D to a 3D body (typically a CharacterBody3D) so "
                "it can path across a baked NavigationRegion3D. This is the pathfinding "
                "primitive — the agent computes the route but does NOT move the body on "
                "its own; a movement script must read get_next_path_position() each "
                "physics frame (the response includes a ready-to-use snippet). For a "
                "fully scaffolded chaser, use create_enemy_3d instead. 3D-only: refuses "
                "on a 2D node. Bake a navmesh with bake_navigation_mesh first."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "node_path": {
                        "type": "string",
                        "description": "Scene-relative path to the Node3D / CharacterBody3D that should navigate. The agent is added as its child.",
                    },
                    "name": {
                        "type": "string",
                        "description": "Agent node name. Default 'NavigationAgent3D'.",
                    },
                    "path_desired_distance": {
                        "type": "number",
                        "description": "How close to a path point counts as reaching it. Default 0.5.",
                    },
                    "target_desired_distance": {
                        "type": "number",
                        "description": "How close to the target counts as arrived (is_navigation_finished() flips true). Default 0.5.",
                    },
                    "radius": {
                        "type": "number",
                        "description": "Agent radius for avoidance. Default 0.5.",
                    },
                    "height": {
                        "type": "number",
                        "description": "Agent height for avoidance. Default 1.5.",
                    },
                    "max_speed": {
                        "type": "number",
                        "description": "Max speed used by avoidance. Default 5.0.",
                    },
                    "avoidance_enabled": {
                        "type": "boolean",
                        "description": "Enable RVO local avoidance between agents. Default false (only needed with multiple agents).",
                    },
                    "target_position": {
                        "type": "string",
                        "description": "Optional initial target as 'x,y,z' the agent paths toward.",
                    },
                },
                "required": ["node_path"],
            },
        },
    },
]
