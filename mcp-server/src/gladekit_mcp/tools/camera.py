"""
Camera category tools — cameras, Cinemachine, render textures, post processing.
"""

from typing import Dict, List

CATEGORY = {
    "name": "camera",
    "display_name": "Camera & Post-Processing",
    "keywords": [
        "camera",
        "cinemachine",
        "render texture",
        "post processing",
        "post-processing",
        "view",
        "frustum",
        "fov",
        "depth of field",
        "bloom",
    ],
}

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "look_at_game_view",
            "description": (
                "Capture a screenshot of the rendered game view so you can SEE the current "
                "scene and verify it visually. Use this to check your own work after building "
                "or changing visuals — it catches problems node/component inspection cannot: "
                "invisible or missing objects, wrong/pink materials, off-screen or clipped UI, "
                "bad lighting (too dark/blown out), and poor framing. The image is returned to "
                "you as a vision input. Renders the active game camera (works in edit mode). "
                "Call it when the user asks you to 'look at', 'check how it looks', or to fix a "
                "visual issue, and to confirm a visual change had the intended effect."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "maxWidth": {
                        "type": "integer",
                        "description": "Optional cap on the longest image edge in pixels (default 1280, max 2048).",
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_camera",
            "description": "Create a Camera GameObject. For follow/third-person cameras, create a Camera + movement script. For advanced cinematic cameras with blending, use create_cinemachine_virtual_camera instead (requires Cinemachine package).",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "position": {"type": "string"},
                    "rotation": {"type": "string"},
                    "fieldOfView": {"type": "number"},
                    "orthographic": {"type": "boolean"},
                    "nearClip": {"type": "number"},
                    "farClip": {"type": "number"},
                    "clearFlags": {"type": "string"},
                    "backgroundColor": {"type": "string"},
                    "tagMain": {"type": "boolean"},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_camera_properties",
            "description": "Get detailed information about a Camera component including field of view, clipping planes, HDR settings, MSAA, and other properties. Use to inspect camera settings before modifying them.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Path to GameObject with Camera component",
                    }
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_camera_properties",
            "description": "Update Camera properties on a GameObject including HDR and MSAA settings.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Path to GameObject with Camera component",
                    },
                    "fieldOfView": {
                        "type": "number",
                        "description": "Optional: Field of view angle",
                    },
                    "orthographic": {
                        "type": "boolean",
                        "description": "Optional: Whether camera is orthographic",
                    },
                    "nearClip": {
                        "type": "number",
                        "description": "Optional: Near clipping plane distance",
                    },
                    "farClip": {
                        "type": "number",
                        "description": "Optional: Far clipping plane distance",
                    },
                    "clearFlags": {
                        "type": "string",
                        "description": "Optional: Camera clear flags",
                    },
                    "backgroundColor": {
                        "type": "string",
                        "description": "Optional: Background color as 'r,g,b,a'",
                    },
                    "allowHDR": {
                        "type": "boolean",
                        "description": "Optional: Whether HDR is allowed",
                    },
                    "allowMSAA": {
                        "type": "boolean",
                        "description": "Optional: Whether MSAA is allowed",
                    },
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_render_texture",
            "description": "Create a RenderTexture asset.",
            "parameters": {
                "type": "object",
                "properties": {
                    "assetPath": {"type": "string"},
                    "width": {"type": "integer"},
                    "height": {"type": "integer"},
                    "depth": {"type": "integer"},
                    "format": {"type": "string"},
                },
                "required": ["assetPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_cinemachine_virtual_camera",
            "description": "Create a new GameObject with a CinemachineVirtualCamera component. Requires Cinemachine package to be installed. Use this for advanced camera control with follow/look-at targets, camera blending, and cinematic effects.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Optional: Name for the virtual camera. Default: 'CM vcam'",
                    },
                    "parentPath": {
                        "type": "string",
                        "description": "Optional: Path to parent GameObject",
                    },
                    "position": {
                        "type": "string",
                        "description": "Optional: Position as 'x,y,z'",
                    },
                    "priority": {
                        "type": "integer",
                        "description": "Optional: Camera priority (higher = more important). Default: 10",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_cinemachine_virtual_camera_properties",
            "description": "Get detailed information about a CinemachineVirtualCamera component including priority, follow target, look at target, and other properties. Use to inspect Cinemachine camera settings before modifying them.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Path to GameObject with CinemachineVirtualCamera component",
                    }
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_cinemachine_virtual_camera_properties",
            "description": "Set properties on a CinemachineVirtualCamera component including priority, follow target, look at target, and enabled state.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Path to GameObject with CinemachineVirtualCamera component",
                    },
                    "priority": {
                        "type": "integer",
                        "description": "Optional: Camera priority (higher = more important)",
                    },
                    "followTarget": {
                        "type": "string",
                        "description": "Optional: Path to GameObject to follow (or empty string to clear)",
                    },
                    "lookAtTarget": {
                        "type": "string",
                        "description": "Optional: Path to GameObject to look at (or empty string to clear)",
                    },
                    "enabled": {
                        "type": "boolean",
                        "description": "Optional: Whether the virtual camera is enabled",
                    },
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "assign_render_texture",
            "description": "Assign a RenderTexture to a supported component (Camera or RawImage).",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {"type": "string"},
                    "assetPath": {"type": "string"},
                    "componentType": {
                        "type": "string",
                        "description": "Camera or RawImage",
                    },
                },
                "required": ["gameObjectPath", "assetPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_post_processing",
            "description": "Configure a Volume component for post processing.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {"type": "string"},
                    "profilePath": {"type": "string"},
                    "isGlobal": {"type": "boolean"},
                    "weight": {"type": "number"},
                },
                "required": ["gameObjectPath"],
            },
        },
    },
]
