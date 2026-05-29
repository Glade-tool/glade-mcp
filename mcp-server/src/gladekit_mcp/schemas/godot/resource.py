"""
Godot resource tools — material creation + property updates (2 tools).

Godot uses .tres files for human-readable resources (.res for binary).
Materials default to StandardMaterial3D (PBR); pass material_type='shader'
for a ShaderMaterial backed by a custom .gdshader.

`set_material_property` doubles as the assignment tool — pass
`target_node_path` to attach the material to a MeshInstance3D's
surface_override slot. (The plan originally had a separate
assign_material_to_mesh tool; folded in here per the Phase 3 dedupe.)
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
]
