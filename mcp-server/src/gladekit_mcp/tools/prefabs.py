"""
Prefabs category tools — prefab creation, instantiation, and hierarchy editing.
"""

from typing import Dict, List

CATEGORY = {
    "name": "prefabs",
    "display_name": "Prefabs",
    "keywords": ["prefab", "instantiate", "spawn"],
}

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "create_prefab",
            "description": "Create a prefab from a GameObject in the scene",
            "parameters": {
                "type": "object",
                "properties": {
                    "prefabPath": {
                        "type": "string",
                        "description": "Path relative to Assets folder (e.g., 'Prefabs/MyPrefab.prefab')",
                    },
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Name or path of the GameObject to save as prefab",
                    },
                },
                "required": ["prefabPath", "gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "instantiate_prefab",
            "description": "Instantiate a prefab asset into the scene. Returns an error if no prefab exists at prefabPath; when the prefab is new, create it with create_prefab first.",
            "parameters": {
                "type": "object",
                "properties": {
                    "prefabPath": {
                        "type": "string",
                        "description": "Path relative to Assets folder (e.g., 'Prefabs/MyPrefab.prefab')",
                    },
                    "name": {
                        "type": "string",
                        "description": "Optional: Name for the instantiated GameObject",
                    },
                },
                "required": ["prefabPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_prefab_transform",
            "description": "Set transform properties (position, rotation, scale) on a prefab asset's root object. This edits the prefab asset directly, affecting all future instantiations. Use this to modify prefab assets (e.g., scale enemies to make them smaller). IMPORTANT: Scaling the root will also scale colliders and nav/avoidance radii. If you want visuals smaller but gameplay size unchanged, scale only the model child instead.",
            "parameters": {
                "type": "object",
                "properties": {
                    "prefabPath": {
                        "type": "string",
                        "description": "Path relative to Assets folder (e.g., 'Assets/Enemies/CrabEnemy.prefab')",
                    },
                    "position": {
                        "type": "string",
                        "description": "Optional: Local position as 'x,y,z'",
                    },
                    "rotation": {
                        "type": "string",
                        "description": "Optional: Local rotation as 'x,y,z' Euler angles in degrees",
                    },
                    "scale": {
                        "type": "string",
                        "description": "Optional: Local scale as 'x,y,z' (e.g., '0.5,0.5,0.5' to make smaller)",
                    },
                    "operation": {
                        "type": "string",
                        "description": "Operation type: 'set' (default, absolute), 'add' (offset), or 'multiply'",
                        "enum": ["set", "add", "multiply"],
                        "default": "set",
                    },
                },
                "required": ["prefabPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_prefab_info",
            "description": "Get information about a prefab asset, including hierarchy, components, and transform properties. Use this to inspect prefab structure before editing.",
            "parameters": {
                "type": "object",
                "properties": {
                    "prefabPath": {
                        "type": "string",
                        "description": "Path relative to Assets folder (e.g., 'Assets/Enemies/CrabEnemy.prefab')",
                    }
                },
                "required": ["prefabPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_prefab_property",
            "description": "Set any property on a prefab asset's objects (root or children). This edits the prefab asset directly, affecting all future instantiations. Use this to modify component properties on prefabs. For transform properties, prefer set_prefab_transform.",
            "parameters": {
                "type": "object",
                "properties": {
                    "prefabPath": {
                        "type": "string",
                        "description": "Path relative to Assets folder (e.g., 'Assets/Enemies/CrabEnemy.prefab')",
                    },
                    "objectPath": {
                        "type": "string",
                        "description": "Optional: Path to child object in prefab hierarchy (e.g., 'Model' or 'Model/Child'). If not provided, uses root object.",
                    },
                    "componentType": {
                        "type": "string",
                        "description": "Component type name (e.g., 'Renderer', 'Collider', 'Rigidbody')",
                    },
                    "propertyName": {
                        "type": "string",
                        "description": "Property name to set (e.g., 'm_Enabled', 'material', 'radius')",
                    },
                    "propertyValue": {
                        "type": "string",
                        "description": "Value to set (will be converted to appropriate type). For vectors use 'x,y,z', for colors use 'r,g,b,a'",
                    },
                },
                "required": [
                    "prefabPath",
                    "componentType",
                    "propertyName",
                    "propertyValue",
                ],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "add_prefab_component",
            "description": "Add a component to a prefab asset's objects (root or children). This edits the prefab asset directly, affecting all future instantiations. Use this to add components like Collider, Rigidbody, Renderer, etc. to prefabs.",
            "parameters": {
                "type": "object",
                "properties": {
                    "prefabPath": {
                        "type": "string",
                        "description": "Path relative to Assets folder (e.g., 'Assets/Enemies/CrabEnemy.prefab')",
                    },
                    "objectPath": {
                        "type": "string",
                        "description": "Optional: Path to child object in prefab hierarchy (e.g., 'Model' or 'Model/Child'). If not provided, uses root object.",
                    },
                    "componentType": {
                        "type": "string",
                        "description": "Component type name (e.g., 'BoxCollider', 'Rigidbody', 'Renderer', 'MyScript')",
                    },
                },
                "required": ["prefabPath", "componentType"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "remove_prefab_component",
            "description": "Remove a component from a prefab asset's objects (root or children). This edits the prefab asset directly, affecting all future instantiations.",
            "parameters": {
                "type": "object",
                "properties": {
                    "prefabPath": {
                        "type": "string",
                        "description": "Path relative to Assets folder (e.g., 'Assets/Enemies/CrabEnemy.prefab')",
                    },
                    "objectPath": {
                        "type": "string",
                        "description": "Optional: Path to child object in prefab hierarchy (e.g., 'Model' or 'Model/Child'). If not provided, uses root object.",
                    },
                    "componentType": {
                        "type": "string",
                        "description": "Component type name (e.g., 'BoxCollider', 'Rigidbody', 'Renderer')",
                    },
                },
                "required": ["prefabPath", "componentType"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_prefab_gameobject_property",
            "description": "Set GameObject properties (active, layer, tag) on prefab assets. This edits the prefab asset directly, affecting all future instantiations.",
            "parameters": {
                "type": "object",
                "properties": {
                    "prefabPath": {
                        "type": "string",
                        "description": "Path relative to Assets folder (e.g., 'Assets/Enemies/CrabEnemy.prefab')",
                    },
                    "objectPath": {
                        "type": "string",
                        "description": "Optional: Path to child object in prefab hierarchy (e.g., 'Model' or 'Model/Child'). If not provided, uses root object.",
                    },
                    "active": {
                        "type": "boolean",
                        "description": "Optional: Set active state (true/false)",
                    },
                    "layer": {
                        "type": "integer",
                        "description": "Optional: Set layer index (0-31)",
                    },
                    "tag": {"type": "string", "description": "Optional: Set tag name"},
                },
                "required": ["prefabPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "rename_prefab_object",
            "description": "Rename objects in prefab assets (root or children). This edits the prefab asset directly, affecting all future instantiations.",
            "parameters": {
                "type": "object",
                "properties": {
                    "prefabPath": {
                        "type": "string",
                        "description": "Path relative to Assets folder (e.g., 'Assets/Enemies/CrabEnemy.prefab')",
                    },
                    "objectPath": {
                        "type": "string",
                        "description": "Optional: Path to child object in prefab hierarchy (e.g., 'Model' or 'Model/Child'). If not provided, renames root object.",
                    },
                    "newName": {
                        "type": "string",
                        "description": "New name for the object",
                    },
                },
                "required": ["prefabPath", "newName"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "add_prefab_child",
            "description": "Add a child GameObject to a prefab asset. This edits the prefab asset directly, affecting all future instantiations. Can create empty GameObjects or primitives (Cube, Sphere, etc.).",
            "parameters": {
                "type": "object",
                "properties": {
                    "prefabPath": {
                        "type": "string",
                        "description": "Path relative to Assets folder (e.g., 'Assets/Enemies/CrabEnemy.prefab')",
                    },
                    "parentPath": {
                        "type": "string",
                        "description": "Optional: Path to parent object in prefab hierarchy (e.g., 'Model' or 'Model/Child'). If not provided, adds to root object.",
                    },
                    "childName": {
                        "type": "string",
                        "description": "Name for the new child GameObject",
                        "default": "GameObject",
                    },
                    "primitiveType": {
                        "type": "string",
                        "description": "Optional: Create a primitive instead of empty GameObject. Options: 'Cube', 'Sphere', 'Capsule', 'Cylinder', 'Plane', 'Quad'",
                    },
                },
                "required": ["prefabPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "remove_prefab_child",
            "description": "Remove/delete a child object from a prefab asset. This edits the prefab asset directly, affecting all future instantiations. Cannot remove the root object (use delete_asset to delete the entire prefab).",
            "parameters": {
                "type": "object",
                "properties": {
                    "prefabPath": {
                        "type": "string",
                        "description": "Path relative to Assets folder (e.g., 'Assets/Enemies/CrabEnemy.prefab')",
                    },
                    "childPath": {
                        "type": "string",
                        "description": "Path to child object in prefab hierarchy (e.g., 'Model' or 'Model/Child'). Cannot be the root object.",
                    },
                },
                "required": ["prefabPath", "childPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_prefab_parent",
            "description": "Reparent an object within a prefab asset. This edits the prefab asset directly, affecting all future instantiations. Use this to reorganize prefab hierarchy.",
            "parameters": {
                "type": "object",
                "properties": {
                    "prefabPath": {
                        "type": "string",
                        "description": "Path relative to Assets folder (e.g., 'Assets/Enemies/CrabEnemy.prefab')",
                    },
                    "childPath": {
                        "type": "string",
                        "description": "Path to child object to reparent (e.g., 'Model' or 'Model/Child')",
                    },
                    "parentPath": {
                        "type": "string",
                        "description": "Optional: Path to new parent object. If not provided or empty, reparents to root.",
                    },
                    "worldPositionStays": {
                        "type": "boolean",
                        "description": "Optional: If true, keeps world position when reparenting. Default: true",
                    },
                },
                "required": ["prefabPath", "childPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "duplicate_prefab_object",
            "description": "Duplicate an object within a prefab asset. This creates a copy with all components and children. This edits the prefab asset directly, affecting all future instantiations.",
            "parameters": {
                "type": "object",
                "properties": {
                    "prefabPath": {
                        "type": "string",
                        "description": "Path relative to Assets folder (e.g., 'Assets/Enemies/CrabEnemy.prefab')",
                    },
                    "objectPath": {
                        "type": "string",
                        "description": "Path to object to duplicate (e.g., 'Model' or 'Model/Child')",
                    },
                    "newName": {
                        "type": "string",
                        "description": "Optional: Name for the duplicate. If not provided, auto-generates name. If count > 1, appends (1), (2), etc.",
                    },
                    "parentPath": {
                        "type": "string",
                        "description": "Optional: Path to parent for duplicates. If not provided, duplicates under same parent as original.",
                    },
                    "count": {
                        "type": "integer",
                        "description": "Optional: Number of duplicates to create. Default: 1, Max: 100",
                    },
                },
                "required": ["prefabPath", "objectPath"],
            },
        },
    },
]
