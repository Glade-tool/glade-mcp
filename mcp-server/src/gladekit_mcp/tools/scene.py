"""
Scene category tools — GameObject creation, hierarchy manipulation, transforms, components.
"""

from typing import Dict, List

CATEGORY = {
    "name": "scene",
    "display_name": "Scene & GameObjects",
    "keywords": [
        "create",
        "object",
        "gameobject",
        "primitive",
        "cube",
        "sphere",
        "plane",
        "transform",
        "position",
        "move",
        "rotate",
        "scale",
        "parent",
        "layer",
        "tag",
        "duplicate",
        "rename",
        "destroy",
        "delete",
        "group",
        "align",
        "snap",
        "component",
        "tilemap",
        "tile",
        "grid",
        "2d level",
        "parallax",
        "background",
        "platformer",
    ],
}

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "create_game_object",
            "description": "Create an EMPTY GameObject with no mesh, no collider, no visual representation — only a Transform. Use ONLY for invisible logic-only nodes / hierarchy parents (e.g. 'GameManager', 'EnemySpawner', empty pivots). For ANY visible scene object (player capsule, enemy, prop, platform, ground), use create_primitive instead — create_game_object on a visible object produces an invisible Transform with no body and the user will see nothing in the Game view.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Name of the GameObject"},
                    "parent": {
                        "type": "string",
                        "description": "Optional: Name or path of parent GameObject",
                    },
                },
                "required": ["name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_primitive",
            "description": "Create a VISIBLE primitive GameObject (Cube, Sphere, Capsule, Cylinder, Plane, Quad) at origin — comes with MeshFilter + MeshRenderer + Collider attached so it shows up in the Game view immediately. Use this for ANY visible scene object: player capsules, enemies, platforms, props, ground planes, level geometry. Do NOT use create_game_object for visible objects — that produces an empty invisible Transform. Follow up with set_transform for non-origin positioning and create_material + assign_material_to_renderer for non-default colors.",
            "parameters": {
                "type": "object",
                "properties": {
                    "primitiveType": {
                        "type": "string",
                        "description": "Type of primitive: Cube, Sphere, Capsule, Cylinder, Plane, Quad",
                        "enum": [
                            "Cube",
                            "Sphere",
                            "Capsule",
                            "Cylinder",
                            "Plane",
                            "Quad",
                        ],
                    },
                    "name": {
                        "type": "string",
                        "description": "Optional: Name for the GameObject",
                    },
                    "parent": {
                        "type": "string",
                        "description": "Optional: Name or path of parent GameObject",
                    },
                },
                "required": ["primitiveType"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "destroy_game_object",
            "description": "Destroy a GameObject from the scene",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Name or path of the GameObject to destroy",
                    }
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "destroy_game_object_batch",
            "description": "Destroy multiple GameObjects in the scene.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPaths": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Paths of GameObjects to destroy",
                    }
                },
                "required": ["gameObjectPaths"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_game_object_active",
            "description": "Set a GameObject's active state (enable/disable)",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Name or path of the GameObject",
                    },
                    "active": {
                        "type": "boolean",
                        "description": "True to enable, false to disable",
                    },
                },
                "required": ["active"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_game_object_parent",
            "description": "Reparent a GameObject — make it a child of another GameObject (or move it to the scene root). Use this for any 'attach X to Y', 'parent X under Y', 'put X inside Y', or hierarchy-restructuring request. NOT related to IK/animation rigging.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Name or path of the GameObject",
                    },
                    "parentPath": {
                        "type": "string",
                        "description": "Name or path of the new parent GameObject (null for root)",
                    },
                    "worldPositionStays": {
                        "type": "boolean",
                        "description": "Whether to keep world position when reparenting",
                        "default": True,
                    },
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_game_object_property",
            "description": "Set a property on a GameObject",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Name or path of the GameObject",
                    },
                    "propertyName": {
                        "type": "string",
                        "description": "Name of the property to set",
                    },
                    "value": {
                        "type": "string",
                        "description": "Value to set (will be converted to appropriate type)",
                    },
                },
                "required": ["gameObjectPath", "propertyName", "value"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "duplicate_game_object",
            "description": "Duplicate a GameObject in the scene. Returns the path to the new duplicate.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Path to the GameObject to duplicate",
                    },
                    "newName": {
                        "type": "string",
                        "description": "Optional: Name for the duplicate (defaults to 'OriginalName (1)')",
                    },
                    "parentPath": {
                        "type": "string",
                        "description": "Optional: Path to a new parent for the duplicate",
                    },
                    "count": {
                        "type": "integer",
                        "description": "Optional: Number of duplicates to create. Default: 1",
                    },
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "rename_game_object",
            "description": "Rename a GameObject in the scene.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Path to the GameObject to rename",
                    },
                    "newName": {
                        "type": "string",
                        "description": "The new name for the GameObject",
                    },
                },
                "required": ["gameObjectPath", "newName"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_children",
            "description": "List children of a GameObject. Returns paths to child objects.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Path to the parent GameObject",
                    },
                    "recursive": {
                        "type": "boolean",
                        "description": "If true, list all descendants recursively. Default: false (direct children only)",
                    },
                    "includeInactive": {
                        "type": "boolean",
                        "description": "If true, include inactive children. Default: true",
                    },
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_layer",
            "description": "Set the layer of a GameObject (and optionally its children).",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Path to the GameObject",
                    },
                    "layer": {
                        "type": "string",
                        "description": "Layer name (e.g., 'Default', 'UI', 'Ignore Raycast') or layer index (0-31)",
                    },
                    "recursive": {
                        "type": "boolean",
                        "description": "If true, also set layer on all children. Default: false",
                    },
                },
                "required": ["gameObjectPath", "layer"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_tag",
            "description": "Set the tag of a GameObject. The tag must already exist in the Tag Manager.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Path to the GameObject",
                    },
                    "tag": {
                        "type": "string",
                        "description": "Tag name (e.g., 'Player', 'Enemy', 'Untagged'). Must be a valid tag in the project.",
                    },
                },
                "required": ["gameObjectPath", "tag"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "snap_to_ground",
            "description": "Snap one or more GameObjects to the ground by raycasting down. Use this tool when objects need to be adjusted to ground level (e.g., objects are floating or positioned incorrectly).",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPaths": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of GameObject paths to snap. If empty, uses current selection.",
                    },
                    "offset": {
                        "type": "number",
                        "description": "Vertical offset from ground. Default: 0",
                    },
                    "maxDistance": {
                        "type": "number",
                        "description": "Maximum raycast distance. Default: 1000",
                    },
                    "layerMask": {
                        "type": "string",
                        "description": "Optional: Layer mask for raycast (layer name or 'Everything'). Default: 'Everything'",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "align_objects",
            "description": "Align multiple GameObjects along a specified axis. Aligns to the min, center, or max bound of the target or first object.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPaths": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of GameObject paths to align. If empty, uses current selection.",
                    },
                    "axis": {
                        "type": "string",
                        "enum": ["x", "y", "z"],
                        "description": "Axis to align along: 'x', 'y', or 'z'",
                    },
                    "alignTo": {
                        "type": "string",
                        "enum": ["min", "center", "max", "first"],
                        "description": "Alignment target: 'min', 'center', 'max' of bounds, or 'first' object's position. Default: 'first'",
                    },
                    "targetPath": {
                        "type": "string",
                        "description": "Optional: Specific GameObject to align to. If not provided, uses first object or calculates from selection.",
                    },
                },
                "required": ["axis"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "distribute_objects",
            "description": "Evenly distribute multiple GameObjects along an axis with consistent spacing.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPaths": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of GameObject paths to distribute. If empty, uses current selection.",
                    },
                    "axis": {
                        "type": "string",
                        "enum": ["x", "y", "z"],
                        "description": "Axis to distribute along: 'x', 'y', or 'z'",
                    },
                    "spacing": {
                        "type": "number",
                        "description": "Optional: Fixed spacing between objects. If not provided, distributes evenly between first and last.",
                    },
                    "startPosition": {
                        "type": "number",
                        "description": "Optional: Starting position on the axis. If not provided, uses first object's position.",
                    },
                },
                "required": ["axis"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "group_objects",
            "description": "Create a new empty parent GameObject and parent the specified objects under it. Useful for organizing scene hierarchy.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPaths": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of GameObject paths to group. If empty, uses current selection.",
                    },
                    "groupName": {
                        "type": "string",
                        "description": "Name for the new parent GameObject. Default: 'Group'",
                    },
                    "centerPivot": {
                        "type": "boolean",
                        "description": "If true, position group at center of children's bounds. If false, at origin. Default: true",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_group",
            "description": "Create an empty parent GameObject and optionally parent specified objects under it.",
            "parameters": {
                "type": "object",
                "properties": {
                    "groupName": {
                        "type": "string",
                        "description": "Name for the group",
                    },
                    "gameObjectPaths": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Optional: Objects to parent under the group",
                    },
                    "parentPath": {
                        "type": "string",
                        "description": "Optional: Parent for the group",
                    },
                    "centerPivot": {
                        "type": "boolean",
                        "description": "Center the group at combined bounds. Default: true",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_transform",
            "description": "Set world position/rotation/scale of a GameObject. Required after create_primitive when positioning is specified. Use get_gameobject_info to find a reference object's position, then calculate and set the target.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Name of the GameObject to move (e.g., 'RedCube', 'BlueCube'). REQUIRED when you created multiple objects.",
                    },
                    "position": {
                        "type": "string",
                        "description": "Position as 'x,y,z' (e.g., '5,1,0'). Calculate based on reference object position.",
                    },
                    "rotation": {
                        "type": "string",
                        "description": "Rotation as 'x,y,z' Euler angles in degrees",
                    },
                    "scale": {"type": "string", "description": "Scale as 'x,y,z'"},
                    "operation": {
                        "type": "string",
                        "description": "Operation: 'set' (absolute), 'add' (offset), 'multiply' (scale)",
                        "enum": ["set", "add", "multiply"],
                        "default": "set",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_local_transform",
            "description": "Set local transform (position, rotation, scale) of a GameObject relative to its parent. REQUIRED when requests specify positioning relative to a parent. Use get_gameobject_info to find reference positions, then calculate target positions. Use 'set' for absolute values, 'add' to offset from current, 'multiply' to scale current values. Always call this after create_primitive/create_game_object when positioning is specified in the request.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Optional: Name or path of the GameObject (uses selected if not provided)",
                    },
                    "position": {
                        "type": "string",
                        "description": "Optional: Local position as 'x,y,z'",
                    },
                    "rotation": {
                        "type": "string",
                        "description": "Optional: Local rotation as 'x,y,z' Euler angles",
                    },
                    "scale": {
                        "type": "string",
                        "description": "Optional: Local scale as 'x,y,z'",
                    },
                    "operation": {
                        "type": "string",
                        "description": "Operation type: 'set' (default), 'add', or 'multiply'",
                        "enum": ["set", "add", "multiply"],
                        "default": "set",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_transform_batch",
            "description": "Apply transforms to multiple objects in one call.",
            "parameters": {
                "type": "object",
                "properties": {
                    "transforms": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "gameObjectPath": {"type": "string"},
                                "position": {"type": "string"},
                                "rotation": {"type": "string"},
                                "scale": {"type": "string"},
                                "operation": {
                                    "type": "string",
                                    "enum": ["set", "add", "multiply"],
                                },
                            },
                        },
                    }
                },
                "required": ["transforms"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_gameobject_components",
            "description": "List components on a specific GameObject. Returns component names and missing script count. If you need Inspector-visible component fields, call get_component_inspector_properties after this.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Path to the GameObject",
                    }
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_component_inspector_properties",
            "description": "Read Inspector-visible serialized properties from a component on a GameObject. Use this after get_gameobject_components when you need the same fields shown in the Inspector. Names use displayName; internalName/path are included for exact matching.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Path to the GameObject",
                    },
                    "componentType": {
                        "type": "string",
                        "description": "Component type name (e.g., Animator or UnityEngine.Animator)",
                    },
                    "propertyFilter": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Optional: property name or propertyPath whitelist",
                    },
                    "onlyReferences": {
                        "type": "boolean",
                        "description": "Only include Object reference fields. Default: false",
                    },
                    "onlyUnassigned": {
                        "type": "boolean",
                        "description": "Only include unassigned Object references. Default: false",
                    },
                    "onlyTopLevel": {
                        "type": "boolean",
                        "description": "Only include top-level properties (no nested/array children). Default: true",
                    },
                },
                "required": ["gameObjectPath", "componentType"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "add_component",
            "description": "Add a component to a GameObject. Verify the GameObject exists in the scene hierarchy (check Unity context). For script components, ensure the script has been compiled first.",
            "parameters": {
                "type": "object",
                "properties": {
                    "componentType": {
                        "type": "string",
                        "description": "Type name of the component (e.g., 'Rigidbody', 'MeshRenderer', 'MyScript'). Must match the exact class name (case-sensitive).",
                    },
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Optional: Name or path of the GameObject from scene hierarchy (uses selected GameObject if not provided)",
                    },
                },
                "required": ["componentType"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "remove_component",
            "description": "Remove a component from a GameObject",
            "parameters": {
                "type": "object",
                "properties": {
                    "componentType": {
                        "type": "string",
                        "description": "Type name of the component to remove",
                    },
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Optional: Name or path of the GameObject (uses selected if not provided)",
                    },
                },
                "required": ["componentType"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_component_property",
            "description": "Set a property on a built-in Unity component (Rigidbody, MeshRenderer, Light, Camera, etc.). Supports primitives, Vector3/Color/Quaternion, enums (provide name as string), and asset references (provide asset path). For scene object references, use set_object_reference. Use appendToList=true for List<T>/arrays.",
            "parameters": {
                "type": "object",
                "properties": {
                    "componentType": {
                        "type": "string",
                        "description": "Type name of the component (e.g., 'Rigidbody', 'MeshRenderer', 'Light', 'Camera')",
                    },
                    "propertyName": {
                        "type": "string",
                        "description": "Name of the property or field to set (e.g., 'mass', 'material', 'intensity', 'myEnumField'). For enum dropdowns, provide the enum name. For lists, use appendToList=true to append items.",
                    },
                    "value": {
                        "type": "string",
                        "description": "Value to set (will be converted to appropriate type). For enums (dropdowns), provide the enum value name as a string (e.g., 'MyEnumValue'). For asset references, provide the asset path. For lists with appendToList=true, can be a single item or JSON array like '[item1, item2]'.",
                    },
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Optional: Name or path of the GameObject (uses selected if not provided)",
                    },
                    "appendToList": {
                        "type": "boolean",
                        "description": "If true and the property is a List<T> or array, append the value(s) to the existing list instead of replacing it. This safely preserves existing items and supports undo/redo. Default: false.",
                        "default": False,
                    },
                },
                "required": ["componentType", "propertyName", "value"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_script_component_property",
            "description": "Set a property on a custom script component (MonoBehaviour) on a GameObject, found by script name (flexible matching). For built-in components, use set_component_property instead. Supports primitives, Vector3/Color/Quaternion, enums, and asset references. Use appendToList=true for List<T>/arrays.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Name or path of the GameObject that has the script component",
                    },
                    "scriptName": {
                        "type": "string",
                        "description": "Name of the script component class (e.g., 'PetController', 'GameManager'). Can be partial match - the tool will find the component.",
                    },
                    "propertyName": {
                        "type": "string",
                        "description": "Name of the property or field to set (e.g., 'petId', 'displayName', 'portrait', 'prefab', 'petDefinitions', 'myEnumField'). For enum dropdowns, provide the enum name. For lists, use appendToList=true to append items.",
                    },
                    "value": {
                        "type": "string",
                        "description": "Value to set (will be converted to appropriate type). For enums (dropdowns), provide the enum value name as a string (e.g., 'MyEnumValue'). For asset references, provide the asset path (e.g., 'Assets/Prefabs/MyPrefab.prefab' or 'Assets/Sprites/MySprite.png'). For lists with appendToList=true, can be a single item or JSON array like '[item1, item2]'.",
                    },
                    "appendToList": {
                        "type": "boolean",
                        "description": "If true and the property is a List<T> or array, append the value(s) to the existing list instead of replacing it. This safely preserves existing items and supports undo/redo. Default: false.",
                        "default": False,
                    },
                },
                "required": ["gameObjectPath", "scriptName", "propertyName", "value"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_object_reference",
            "description": "Set an object reference field on a component. Use ONLY for built-in Unity components and prefab setup — NOT for runtime script fields. Scripts must be self-contained and find their own references via Start()/Awake().",
            "parameters": {
                "type": "object",
                "properties": {
                    "targetGameObject": {
                        "type": "string",
                        "description": "Name or path of the GameObject that has the component to modify",
                    },
                    "componentType": {
                        "type": "string",
                        "description": "Type name of the component on the target GameObject",
                    },
                    "fieldName": {
                        "type": "string",
                        "description": "Name of the field/property to set (e.g., 'target', 'player', 'mainCamera')",
                    },
                    "sourceGameObject": {
                        "type": "string",
                        "description": "Name or path of the GameObject to reference (or whose component to reference)",
                    },
                    "sourceType": {
                        "type": "string",
                        "description": "What to assign: 'GameObject' (the GameObject itself), 'Transform', or a component type name like 'Rigidbody', 'Camera', etc. Default: 'Transform'",
                    },
                },
                "required": [
                    "targetGameObject",
                    "componentType",
                    "fieldName",
                    "sourceGameObject",
                ],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_tilemap",
            "description": "Create a Grid + Tilemap + TilemapRenderer — the foundation for tile-based 2D levels (platformers, top-down RPGs). Returns gridPath and tilemapPath. Call again with gridPath to stack more layers (background / foreground / hazards) on the same grid. Paint it with set_tilemap_tiles, then make it solid with add_tilemap_collider_2d.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Tilemap layer name. Defaults to 'Tilemap'. A numeric suffix is added if the name is taken.",
                    },
                    "gridPath": {
                        "type": "string",
                        "description": "Existing Grid to attach this layer to (from a previous create_tilemap call). Omit to create a new Grid.",
                    },
                    "layout": {
                        "type": "string",
                        "enum": ["rectangular", "isometric", "hexagonal"],
                        "description": "Cell layout of a NEW grid. Defaults to rectangular. Ignored with gridPath.",
                    },
                    "cellSize": {
                        "type": "string",
                        "description": "Cell size in world units as 'x,y' for a NEW grid. Defaults to '1,1'.",
                    },
                    "sortingOrder": {
                        "type": "integer",
                        "description": "Render order of this layer (higher draws on top). Defaults to 0.",
                    },
                    "position": {
                        "type": "string",
                        "description": "World position of a NEW grid as 'x,y'. Defaults to '0,0'.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_tilemap_tiles",
            "description": "Paint or erase tiles on a Tilemap (pairs with create_tilemap). Cells are TILE units, not world units: list them as 'x,y;x,y;...' and/or fill a rectangle with fillRect 'x,y,w,h'. Pass a Tile asset (tilePath) or just a sprite (spritePath, plus spriteName for a sliced sheet) — a reusable Tile asset is created next to the sprite automatically. Set erase=true to clear the listed cells instead.",
            "parameters": {
                "type": "object",
                "properties": {
                    "tilemapPath": {
                        "type": "string",
                        "description": "Path to the Tilemap (returned by create_tilemap)",
                    },
                    "tilePath": {"type": "string", "description": "A ready Tile .asset to stamp"},
                    "spritePath": {
                        "type": "string",
                        "description": "A sprite to stamp — a Tile asset wrapping it is find-or-created next to it",
                    },
                    "spriteName": {
                        "type": "string",
                        "description": "Sprite name inside a sliced spritesheet at spritePath",
                    },
                    "cells": {
                        "type": "string",
                        "description": "Individual cells as 'x,y;x,y;...' (tile units, integers)",
                    },
                    "fillRect": {
                        "type": "string",
                        "description": "Fill a w×h block as 'x,y,w,h' (tile units, integers). E.g. '-10,0,20,1' paints a 20-tile floor.",
                    },
                    "erase": {
                        "type": "boolean",
                        "description": "Clear the listed cells/rect instead of painting. Defaults to false.",
                    },
                },
                "required": ["tilemapPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "add_tilemap_collider_2d",
            "description": "Make a painted Tilemap SOLID so 2D physics bodies can stand on it. A tilemap is purely visual until this runs — a Rigidbody2D player falls straight through the floor. composite=true merges per-tile boxes into clean outlines (prevents ghost-collision seams between tiles; recommended for level geometry). oneWay=true makes platforms the player can jump up through and land on.",
            "parameters": {
                "type": "object",
                "properties": {
                    "tilemapPath": {"type": "string", "description": "Path to the painted Tilemap"},
                    "composite": {
                        "type": "boolean",
                        "description": "Merge per-tile colliders into clean outlines via CompositeCollider2D + static Rigidbody2D. Defaults to false.",
                    },
                    "isTrigger": {
                        "type": "boolean",
                        "description": "Make the tiles a trigger zone (reports overlaps, doesn't block). Defaults to false.",
                    },
                    "oneWay": {
                        "type": "boolean",
                        "description": "One-way platforms via PlatformEffector2D: jump up through, land on top. Defaults to false.",
                    },
                },
                "required": ["tilemapPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_tilemap_info",
            "description": "Read-only snapshot of a tile level: grid layout and cell size plus, per layer, the painted bounds (tile units), tile count, sorting order, and whether it has a collider yet. Accepts a Grid path (describes every layer under it) or a single Tilemap path.",
            "parameters": {
                "type": "object",
                "properties": {
                    "tilemapPath": {"type": "string", "description": "Path to a Grid or Tilemap GameObject"}
                },
                "required": ["tilemapPath"],
            },
        },
    },
]
