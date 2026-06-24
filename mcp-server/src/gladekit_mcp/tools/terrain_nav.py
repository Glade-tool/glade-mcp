"""
Terrain & NavMesh category tools — terrain creation, NavMesh baking, agents, obstacles, links.
"""

from typing import Dict, List

CATEGORY = {
    "name": "terrain_nav",
    "display_name": "Terrain & Navigation",
    "keywords": [
        "terrain",
        "navmesh",
        "navigation",
        "pathfinding",
        "nav agent",
        "obstacle",
        "nav link",
        "bake",
        "walkable",
        "area mask",
    ],
}

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "create_terrain",
            "description": "Create a Terrain with a new TerrainData asset.",
            "parameters": {
                "type": "object",
                "properties": {
                    "terrainDataPath": {"type": "string"},
                    "name": {"type": "string"},
                    "position": {"type": "string"},
                    "size": {"type": "string"},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_terrain_properties",
            "description": "Update TerrainData properties. Can modify terrain size and resolutions. For material/shader issues on terrain prototypes (trees, mushrooms, stumps, etc.), use convert_materials_to_render_pipeline instead - it automatically finds ALL materials using a shader across the entire project (including materials on terrain prototype prefabs) and converts them.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Path to GameObject with Terrain component",
                    },
                    "terrainDataPath": {
                        "type": "string",
                        "description": "Path to TerrainData asset (alternative to gameObjectPath)",
                    },
                    "size": {
                        "type": "string",
                        "description": "Terrain size as 'x,y,z'",
                    },
                    "heightmapResolution": {
                        "type": "integer",
                        "description": "Heightmap resolution",
                    },
                    "baseMapResolution": {
                        "type": "integer",
                        "description": "Base map resolution",
                    },
                    "detailResolution": {
                        "type": "integer",
                        "description": "Detail resolution",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_navmesh_surface",
            "description": "Create or configure a NavMeshSurface component.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {"type": "string"},
                    "collectObjects": {
                        "type": "string",
                        "enum": ["All", "Children", "Volume"],
                    },
                    "layerMask": {"type": "string"},
                    "useGeometry": {
                        "type": "string",
                        "enum": ["RenderMeshes", "PhysicsColliders"],
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "bake_navmesh",
            "description": "Build NavMesh for a specific NavMeshSurface or all surfaces.",
            "parameters": {
                "type": "object",
                "properties": {"gameObjectPath": {"type": "string"}},
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_navmesh_agent",
            "description": "Add/update NavMeshAgent settings.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {"type": "string"},
                    "radius": {"type": "number"},
                    "height": {"type": "number"},
                    "speed": {"type": "number"},
                    "acceleration": {"type": "number"},
                    "angularSpeed": {"type": "number"},
                    "stoppingDistance": {"type": "number"},
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "calculate_navmesh_path",
            "description": "Calculate path between two positions on NavMesh. Returns path existence, length, and corners.",
            "parameters": {
                "type": "object",
                "properties": {
                    "startPosition": {"type": "string"},
                    "endPosition": {"type": "string"},
                    "agentTypeID": {"type": "integer"},
                    "areaMask": {"type": "integer"},
                },
                "required": ["startPosition", "endPosition"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "sample_navmesh_position",
            "description": "Find nearest valid NavMesh position from a given position.",
            "parameters": {
                "type": "object",
                "properties": {
                    "position": {"type": "string"},
                    "maxDistance": {"type": "number"},
                    "agentTypeID": {"type": "integer"},
                    "areaMask": {"type": "integer"},
                },
                "required": ["position"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_navmesh_obstacle",
            "description": "Create NavMeshObstacle component for dynamic obstacles that affect NavMesh.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {"type": "string"},
                    "shape": {"type": "string", "enum": ["Capsule", "Box"]},
                    "carve": {"type": "boolean"},
                    "carveOnlyStationary": {"type": "boolean"},
                    "moveThreshold": {"type": "number"},
                    "timeToStationary": {"type": "number"},
                    "radius": {"type": "number"},
                    "height": {"type": "number"},
                    "size": {"type": "string"},
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_navmesh_obstacle_properties",
            "description": "Update NavMeshObstacle properties.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {"type": "string"},
                    "carve": {"type": "boolean"},
                    "carveOnlyStationary": {"type": "boolean"},
                    "moveThreshold": {"type": "number"},
                    "timeToStationary": {"type": "number"},
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_navmesh_link",
            "description": "Create NavMeshLink for off-mesh connections (jumps, climbing, etc.).",
            "parameters": {
                "type": "object",
                "properties": {
                    "startPosition": {"type": "string"},
                    "endPosition": {"type": "string"},
                    "name": {"type": "string"},
                    "bidirectional": {"type": "boolean"},
                    "activated": {"type": "boolean"},
                    "area": {"type": "integer"},
                    "costModifier": {"type": "number"},
                    "width": {"type": "number"},
                },
                "required": ["startPosition", "endPosition"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_navmesh_link_properties",
            "description": "Update NavMeshLink properties.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {"type": "string"},
                    "startPosition": {"type": "string"},
                    "endPosition": {"type": "string"},
                    "bidirectional": {"type": "boolean"},
                    "activated": {"type": "boolean"},
                    "area": {"type": "integer"},
                    "costModifier": {"type": "number"},
                    "width": {"type": "number"},
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_navmesh_surface_advanced",
            "description": "Configure advanced NavMeshSurface settings including agent type, voxel size, tile size, etc.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {"type": "string"},
                    "agentTypeID": {"type": "integer"},
                    "buildHeightMesh": {"type": "boolean"},
                    "voxelSize": {"type": "number"},
                    "minRegionArea": {"type": "number"},
                    "overrideTileSize": {"type": "boolean"},
                    "tileSize": {"type": "integer"},
                    "overrideVoxelSize": {"type": "boolean"},
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_navmesh_agent_advanced",
            "description": "Configure advanced NavMeshAgent properties including area mask, obstacle avoidance, auto-braking, etc.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {"type": "string"},
                    "areaMask": {"type": "integer"},
                    "agentTypeID": {"type": "integer"},
                    "obstacleAvoidanceType": {"type": "integer"},
                    "avoidancePriority": {"type": "integer"},
                    "autoBraking": {"type": "boolean"},
                    "autoRepath": {"type": "boolean"},
                    "autoTraverseOffMeshLink": {"type": "boolean"},
                    "baseOffset": {"type": "number"},
                    "updatePosition": {"type": "boolean"},
                    "updateRotation": {"type": "boolean"},
                    "updateUpAxis": {"type": "boolean"},
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_navmesh_agent_area_mask",
            "description": "Set walkable area mask for NavMeshAgent. Can use area names array or bitmask.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {"type": "string"},
                    "areaMask": {"type": "integer"},
                    "areaNames": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_navmesh_areas",
            "description": "Get all NavMesh area types with their names, indices, and costs.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_navmesh_area_cost",
            "description": "Set path cost multiplier for a NavMesh area.",
            "parameters": {
                "type": "object",
                "properties": {
                    "areaIndex": {"type": "integer"},
                    "cost": {"type": "number"},
                },
                "required": ["areaIndex", "cost"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "clear_navmesh",
            "description": "Clear baked NavMesh data. Can clear specific surface or all surfaces.",
            "parameters": {
                "type": "object",
                "properties": {"gameObjectPath": {"type": "string"}},
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_navmesh_info",
            "description": "Get NavMesh information including agent count, surface count, data size, bounds, etc.",
            "parameters": {
                "type": "object",
                "properties": {"gameObjectPath": {"type": "string"}},
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_navmesh_bounds",
            "description": "Get NavMesh bounds from a specific surface or combined bounds from all surfaces.",
            "parameters": {
                "type": "object",
                "properties": {"gameObjectPath": {"type": "string"}},
                "required": [],
            },
        },
    },
]
