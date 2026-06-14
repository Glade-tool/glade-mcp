"""
Godot camera, lighting, and environment tools (6 tools).

`create_camera` and `create_light` are dimension-aware: a `space` arg
(`"2d"` | `"3d"`) picks the node family, the same convention
`create_physics_body` uses. `create_camera` makes a Camera3D or Camera2D;
`create_light` covers the 3D Light3D subclasses (DirectionalLight3D /
OmniLight3D / SpotLight3D) and the 2D family (PointLight2D /
DirectionalLight2D / CanvasModulate) behind a single `type` arg.
`set_light_properties` / `get_light_info` are the mutate/read pair for an
existing Light3D.

`set_world_environment` / `get_world_environment` cover scene-wide
rendering: sky, ambient light, fog, tonemap, glow, SSAO. Godot's
WorldEnvironment node + Environment resource is the equivalent of Unity's
RenderSettings. set_world_environment auto-scaffolds the node and resource
when missing, so a single call with property args is enough for "make it
atmospheric / daytime / foggy" prompts.
"""

from typing import Dict, List

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "create_camera",
            "description": (
                "Create a camera node. The `space` arg picks the family: 'space=3d' "
                "(default) makes a Camera3D (perspective, fov, look_at); 'space=2d' "
                "makes a Camera2D (zoom, viewport follow) for platformers / top-down "
                "games. Check the project's workspace from get_project_info first — use "
                "space='2d' in a 2D project. Optionally make it the active camera with "
                "current=true."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "space": {
                        "type": "string",
                        "description": (
                            "Dimension: '3d' (Camera3D) or '2d' (Camera2D). Inferred from "
                            "the open scene's root when omitted, so you usually don't need "
                            "to pass it — set it only to override."
                        ),
                        "enum": ["3d", "2d"],
                    },
                    "name": {"type": "string", "description": "Node name. Default 'Camera3D'/'Camera2D'."},
                    "parent_path": {
                        "type": "string",
                        "description": "Scene-relative parent. Default scene root.",
                    },
                    "current": {
                        "type": "boolean",
                        "description": "Make this the active camera. Default false.",
                    },
                    "fov": {
                        "type": "number",
                        "description": "Field of view in degrees (3D only). Default 75.",
                    },
                    "position": {
                        "type": "string",
                        "description": "Initial position: 'x,y,z' (3D, default '0,0,5') or 'x,y' (2D, default '0,0').",
                    },
                    "look_at": {
                        "type": "string",
                        "description": (
                            "Optional point to orient toward, as 'x,y,z' (3D only). The camera is rotated automatically."
                        ),
                    },
                    "zoom": {
                        "type": "string",
                        "description": (
                            "Camera2D zoom (2D only). A single number for uniform zoom or 'x,y'. "
                            ">1 zooms IN. Default 1."
                        ),
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_light",
            "description": (
                "Create a light node in 3D or 2D, picked by `space`. space='3d' (default): "
                "DirectionalLight3D ('directional'), OmniLight3D ('omni'), SpotLight3D "
                "('spot'). space='2d': PointLight2D ('point'), DirectionalLight2D "
                "('directional'), or a scene-wide CanvasModulate tint ('ambient', the 2D "
                "analogue of ambient/environment color). In a 2D project use space='2d' — "
                "a 2D point light auto-gets a soft radial texture so it actually emits. "
                "3D directional lights get a 45° default rotation."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "space": {
                        "type": "string",
                        "description": (
                            "Dimension: '3d' (Light3D) or '2d' (Light2D / CanvasModulate). "
                            "Inferred from the open scene's root when omitted."
                        ),
                        "enum": ["3d", "2d"],
                    },
                    "type": {
                        "type": "string",
                        "description": (
                            "Light kind. 3D: directional | omni | spot. "
                            "2D: point | directional | ambient (CanvasModulate)."
                        ),
                        "enum": ["directional", "omni", "spot", "point", "ambient"],
                    },
                    "name": {
                        "type": "string",
                        "description": "Node name. Defaults to the Godot class (e.g. 'DirectionalLight3D').",
                    },
                    "parent_path": {
                        "type": "string",
                        "description": "Scene-relative parent. Default scene root.",
                    },
                    "energy": {
                        "type": "number",
                        "description": "Light energy multiplier (3D + 2D Light2D). Default 1.0.",
                    },
                    "color": {
                        "type": "string",
                        "description": "Hex '#rrggbb' or comma-separated 'r,g,b' (0-1). Default white.",
                    },
                    "position": {
                        "type": "string",
                        "description": "Initial position: 'x,y,z' (3D) or 'x,y' (2D). Ignored for 'ambient'.",
                    },
                    "shadow": {
                        "type": "boolean",
                        "description": "Enable shadow casting. Default true (3D), false (2D).",
                    },
                    "texture": {
                        "type": "string",
                        "description": (
                            "res:// texture for a 2D point light (overrides the generated "
                            "radial gradient). 2D 'point' only."
                        ),
                    },
                },
                "required": ["type"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_light_properties",
            "description": (
                "Mutate an existing Light3D (DirectionalLight3D / OmniLight3D / "
                "SpotLight3D). Sets only the properties passed; omitted args leave "
                "current values untouched. Class-aware: spot_angle / spot_attenuation "
                "apply to SpotLight3D only, range applies to Omni/Spot only — wrong-class "
                "args land in `ignored_properties` with a reason and the call still "
                "succeeds for the args that DID apply."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "node_path": {
                        "type": "string",
                        "description": "Scene-relative path to the target Light3D.",
                    },
                    "energy": {
                        "type": "number",
                        "description": "light_energy multiplier (1.0 is default).",
                    },
                    "color": {
                        "type": "string",
                        "description": "Hex '#rrggbb' or comma-separated 'r,g,b' (0-1).",
                    },
                    "shadow_enabled": {
                        "type": "boolean",
                        "description": "Toggle shadow casting.",
                    },
                    "range": {
                        "type": "number",
                        "description": (
                            "omni_range / spot_range. OmniLight3D and SpotLight3D only; ignored on DirectionalLight3D."
                        ),
                    },
                    "spot_angle": {
                        "type": "number",
                        "description": "Spot cone half-angle in degrees. SpotLight3D only.",
                    },
                    "spot_attenuation": {
                        "type": "number",
                        "description": "Falloff exponent along the spot cone. SpotLight3D only.",
                    },
                    "color_temperature": {
                        "type": "number",
                        "description": (
                            "Correlated color temperature in Kelvin (e.g. 6500 daylight, "
                            "2700 warm white). Godot multiplies this onto light_color."
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
            "name": "get_light_info",
            "description": (
                "Read Light3D-specific properties on a node — energy, color, shadows, "
                "color temperature, plus subclass-specific range / spot_angle / "
                "attenuation. Pairs with set_light_properties for 'make it 2x brighter' "
                "or 'swap to warm white' workflows. Read-only — safe in any mode."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "node_path": {
                        "type": "string",
                        "description": "Scene-relative path to the target Light3D.",
                    },
                },
                "required": ["node_path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_world_environment",
            "description": (
                "Scaffold and configure the scene's WorldEnvironment + Environment "
                "in one call. This is the 'make my scene atmospheric / daytime / "
                "foggy' tool — sky background, ambient light, fog, tonemap, glow, "
                "SSAO all live on the Environment resource. Finds or creates a "
                "WorldEnvironment node and its Environment resource as needed, then "
                "applies the property bag. Missing args leave existing values "
                "untouched. When background_mode='sky' and no sky is currently "
                "assigned, auto-scaffolds a ProceduralSkyMaterial so the scene "
                "doesn't render pitch black."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "environment_path": {
                        "type": "string",
                        "description": (
                            "Optional res:// path to an existing Environment .tres. "
                            "Loaded and assigned before property args. Use "
                            "create_resource(type='Environment', ...) first."
                        ),
                    },
                    "background_mode": {
                        "type": "string",
                        "description": "Background source.",
                        "enum": ["clear_color", "color", "sky", "canvas", "keep"],
                    },
                    "background_color": {
                        "type": "string",
                        "description": "Hex '#rrggbb' or 'r,g,b' (0-1). Used when background_mode='color'.",
                    },
                    "ambient_light_source": {
                        "type": "string",
                        "description": "Where ambient light comes from.",
                        "enum": ["background", "disabled", "color", "sky"],
                    },
                    "ambient_light_color": {
                        "type": "string",
                        "description": "Hex or 'r,g,b'. Used when ambient_light_source='color'.",
                    },
                    "ambient_light_energy": {
                        "type": "number",
                        "description": "Ambient light multiplier.",
                    },
                    "fog_enabled": {"type": "boolean", "description": "Toggle volumetric fog."},
                    "fog_light_color": {
                        "type": "string",
                        "description": "Hex or 'r,g,b'. Note: Godot 4 uses fog_light_color, not fog_color.",
                    },
                    "fog_density": {
                        "type": "number",
                        "description": "Fog thickness (0.0 = none, ~0.01 = subtle, ~0.1 = heavy).",
                    },
                    "tonemap_mode": {
                        "type": "string",
                        "description": (
                            "Post-process tonemap operator. 'reinhardt' is the canonical "
                            "spelling (matches Godot's TONE_MAPPER_REINHARDT); 'reinhard' "
                            "is also accepted."
                        ),
                        "enum": ["linear", "reinhardt", "filmic", "aces"],
                    },
                    "tonemap_exposure": {
                        "type": "number",
                        "description": "Exposure multiplier applied before tonemap.",
                    },
                    "glow_enabled": {"type": "boolean", "description": "Toggle screen-space glow / bloom."},
                    "ssao_enabled": {"type": "boolean", "description": "Toggle SSAO ambient occlusion."},
                    "procedural_sky": {
                        "type": "boolean",
                        "description": (
                            "Force-scaffold a ProceduralSkyMaterial even if background_mode "
                            "isn't 'sky'. Implied when background_mode='sky' and no sky "
                            "is currently assigned."
                        ),
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_world_environment",
            "description": (
                "Read the scene's WorldEnvironment + Environment state — sky, ambient, "
                "fog, tonemap, glow, SSAO. Returns has_world_environment=false when no "
                "WorldEnvironment node exists. Pairs with set_world_environment for "
                "'tweak this slightly' workflows. Read-only — safe in any mode."
            ),
            "parameters": {"type": "object", "properties": {}},
        },
    },
]
