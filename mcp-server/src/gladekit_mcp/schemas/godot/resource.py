"""
Godot resource tools (3 tools).

Godot uses .tres files for human-readable resources (.res for binary).

  create_material         specialized creator for Material subclasses, with
                          PBR knobs (albedo / metallic / roughness / emission)
                          and a shader_path path for ShaderMaterial.
  set_material_property   modify an existing material AND/OR assign it to a
                          MeshInstance3D surface_override slot.
  create_resource         generic creator for every other Resource subclass
                          (Mesh / Shape3D / Curve / Environment / AudioStream*
                          / Gradient / Texture variants / etc.). Refuses
                          Material and Script types with a redirect so the
                          three creators stay cleanly partitioned. Composes
                          with set_node_resource to assign the saved file.
"""

from typing import Dict, List

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "create_material",
            "description": (
                "Create a new StandardMaterial3D (default) or ShaderMaterial and save "
                "as a .tres file. Refuses to overwrite — use set_material_property to "
                "modify an existing material. Standard property args (albedo / metallic / "
                "roughness / emission) apply to StandardMaterial3D only."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "res:// path for the .tres file. Auto-appends .tres.",
                    },
                    "material_type": {
                        "type": "string",
                        "description": "Material class.",
                        "enum": ["standard", "shader"],
                    },
                    "shader_path": {
                        "type": "string",
                        "description": "Required when material_type='shader'. res:// path to the shader.",
                    },
                    "albedo": {
                        "type": "string",
                        "description": "Albedo color, hex '#rrggbb' or 'r,g,b' (0-1). StandardMaterial3D only.",
                    },
                    "metallic": {
                        "type": "number",
                        "description": "Metallic 0-1. StandardMaterial3D only.",
                    },
                    "roughness": {
                        "type": "number",
                        "description": "Roughness 0-1. StandardMaterial3D only.",
                    },
                    "emission": {
                        "type": "string",
                        "description": "Emission color. Enables emission automatically. StandardMaterial3D only.",
                    },
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_material_property",
            "description": (
                "Modify a property on an existing material AND/OR assign the material to "
                "a MeshInstance3D node. Pass target_node_path to do the assignment "
                "(the Godot equivalent of assigning a material to a renderer). Backs up the "
                "material .tres before overwriting so a prior version can be recovered."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "material_path": {
                        "type": "string",
                        "description": "res:// path to a .tres material.",
                    },
                    "property": {
                        "type": "string",
                        "description": (
                            "Property name (albedo / metallic / roughness / emission for "
                            "StandardMaterial3D, or any settable property for ShaderMaterial). "
                            "Optional — omit to do assignment only."
                        ),
                    },
                    "value": {
                        "description": "New value (type depends on property). Colors accept '#rrggbb' or 'r,g,b'.",
                    },
                    "target_node_path": {
                        "type": "string",
                        "description": (
                            "Optional: when set, assigns the material to this MeshInstance3D's surface_override slot."
                        ),
                    },
                    "surface": {
                        "type": "integer",
                        "description": "Surface override slot index. Default 0.",
                    },
                },
                "required": ["material_path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_resource",
            "description": (
                "Create a built-in Godot Resource subclass (Mesh, Shape3D, Curve, "
                "Environment, AudioStream*, Gradient, Texture variants, etc.) and "
                "save it as a .tres file. Pair with set_node_resource to assign the "
                "saved file to a node property.\n\n"
                "Use create_material for Material/StandardMaterial3D/ShaderMaterial "
                "and create_script for GDScript/CSharpScript — those have specialized "
                "args and create_resource refuses them with a redirect.\n\n"
                "Refuses to overwrite an existing file (no in-place edit). On unknown "
                "'type', returns up to 5 edit-distance suggestions from the ClassDB "
                "Resource subclasses. On abstract 'type' (e.g. 'Shape3D'), returns "
                "concrete subclasses (e.g. 'BoxShape3D', 'SphereShape3D').\n\n"
                "Example: create_resource(path='res://shapes/box.tres', type='BoxShape3D', "
                "properties={'size': '2,2,2'}). Property values for Vector2/3/4 accept "
                "'x,y,z' strings or [x,y,z] arrays. Color values accept '#rrggbb' or "
                "'r,g,b'. Unknown property keys land in the response's unapplied_properties "
                "array with a reason — fix the name and call again."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": (
                            "res:// path for the .tres file. Auto-appends .tres if no "
                            "extension. Refuses to overwrite an existing file."
                        ),
                    },
                    "type": {
                        "type": "string",
                        "description": (
                            "Godot class name in PascalCase. Must be a concrete (non-"
                            "abstract) Resource subclass registered in ClassDB. "
                            "Examples: 'BoxMesh', 'SphereMesh', 'BoxShape3D', 'Curve', "
                            "'Gradient', 'Environment', 'AudioStreamRandomizer'."
                        ),
                    },
                    "properties": {
                        "type": "object",
                        "description": (
                            "Optional initial property values, keyed by property name. "
                            "Vector2/3/4 accept 'x,y,z' strings or arrays. Color accepts "
                            "'#rrggbb' or 'r,g,b'. Primitives (int/float/bool/string) are "
                            "coerced from JSON. Other types pass through to Godot's "
                            "variant system. Unknown keys surface in unapplied_properties "
                            "with a reason."
                        ),
                        "additionalProperties": True,
                    },
                },
                "required": ["path", "type"],
            },
            "annotations": {
                "title": "Create Resource (.tres)",
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": False,
            },
        },
    },
]
