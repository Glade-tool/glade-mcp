"""
Godot camera, lighting, and environment tools (6 tools).

`create_light` covers DirectionalLight3D, OmniLight3D, and SpotLight3D
behind a single `type` arg — the original three-tool plan was deduped
to one tool with a type parameter, matching the way Godot users actually
reason about lights. `set_light_properties` / `get_light_info` are the
mutate/read pair for an existing Light3D.

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
            "name": "create_camera_3d",
            "description": (
                "Create a Camera3D node and add it to the edited scene. Optionally "
                "orient toward a target via look_at, and/or make it the active camera "
                "via current=true. For 2D scenes use create_node with type='Camera2D'."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Node name. Default 'Camera3D'."},
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
                        "description": "Field of view in degrees. Default 75.",
                    },
                    "position": {
                        "type": "string",
                        "description": "Initial position as 'x,y,z'. Default '0,0,5'.",
                    },
                    "look_at": {
                        "type": "string",
                        "description": (
                            "Optional point to orient toward, as 'x,y,z'. The camera will be rotated automatically."
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
                "Create a Light3D node (DirectionalLight3D / OmniLight3D / SpotLight3D). "
                "The `type` arg picks the subclass — 'directional' for sun-style lighting, "
                "'omni' for point lights, 'spot' for cone lights. Directional lights get "
                "a sensible 45° default rotation if no rotation is passed."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "type": {
                        "type": "string",
                        "description": "Light kind.",
                        "enum": ["directional", "omni", "spot"],
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
                        "description": "Light energy multiplier. Default 1.0.",
                    },
                    "color": {
                        "type": "string",
                        "description": "Hex '#rrggbb' or comma-separated 'r,g,b' (0-1). Default white.",
                    },
                    "position": {
                        "type": "string",
                        "description": "Initial position as 'x,y,z'. Default '0,3,0'.",
                    },
                    "shadow": {
                        "type": "boolean",
                        "description": "Enable shadow casting. Default true.",
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
