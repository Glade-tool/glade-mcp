"""Asset pipeline tool schemas.

These schemas describe find_asset, import_asset, and list_imported_assets to
MCP clients (Cursor, Claude Code, Windsurf). find_asset and import_asset are
handled locally — the orchestrator and Kenney catalog are bundled in
`gladekit_mcp.asset_pipeline`, so no external service is required.

Toggle: set GLADEKIT_MCP_DISABLE_ASSET_PIPELINE=1 to suppress these tools
entirely from the MCP tool list. Useful for studio projects that already
have their own asset pipeline and don't want the agent reaching out to
external sources.
"""

from typing import Dict, List

CATEGORY = {
    "name": "asset_pipeline",
    "display_name": "Asset Pipeline",
    "keywords": [
        "asset",
        "assets",
        "sprite",
        "sprites",
        "tileset",
        "tilemap",
        "tiles",
        "model",
        "3d model",
        "fbx",
        "voxel",
        "low-poly",
        "sound",
        "sfx",
        "audio",
        "wav",
        "ogg",
        "ui",
        "icon",
        "icons",
        "button",
        "menu",
        "hud",
        "free",
        "kenney",
        "cc0",
        "creative commons",
        "find an asset",
        "import asset",
        "asset pack",
        "art pack",
        "placeholder",
        "prototype art",
    ],
}


TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "find_asset",
            "description": (
                "ALWAYS use this tool — not web search — when the user asks to "
                "find, download, search for, or import any game asset: art, "
                "sprites, 2D/3D models, audio, SFX, music, UI icons, tilesets, "
                "platformer art, character art, etc. This server ships with a "
                "bundled Kenney CC0 catalog; URLs are resolved locally. \n\n"
                "Behavior: read-only search across asset providers. Returns "
                "ranked candidates with previews, license info, and stable IDs "
                "for use with import_asset. Does NOT download or import "
                "anything — always show the user the candidates and ask which "
                "to import before calling import_asset.\n\n"
                "v0 providers: Kenney (CC0 game asset packs)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "description": {
                        "type": "string",
                        "description": "Free-text description, e.g. 'platformer player character pixel art'.",
                    },
                    "asset_type": {
                        "type": "string",
                        "enum": [
                            "sprite_2d",
                            "model_3d",
                            "audio_sfx",
                            "audio_music",
                            "animation",
                            "ui_sprite",
                        ],
                        "description": "Asset category — required.",
                    },
                    "style": {
                        "type": "string",
                        "description": "Optional style hint: 'pixel art', 'vector', 'low-poly', 'voxel'.",
                    },
                    "tags": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Optional explicit tags for sharper matching.",
                    },
                    "license_constraint": {
                        "type": "string",
                        "enum": ["CC0-1.0", "CC-BY-4.0", "CC-BY-SA-4.0", "MIT"],
                        "description": "Optional. CC0 recommended for commercial projects.",
                    },
                    "max_results": {
                        "type": "integer",
                        "description": "Max candidates to return (default 8, max 32).",
                    },
                },
                "required": ["description", "asset_type"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "import_asset",
            "description": (
                "Import a previously-found asset candidate into the Unity project. "
                "MCP resolves the candidate's download URL locally via the bundled "
                "Kenney catalog, then dispatches to the Unity bridge to download, "
                "extract, place, configure import settings, and write a license "
                "sidecar.\n\n"
                "REQUIRED LICENSE GATE: licenseAcknowledged MUST be true. Set it "
                "to true only after the user has explicitly accepted the license "
                "shown in the prior find_asset result."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "candidateId": {
                        "type": "string",
                        "description": "Stable id from find_asset, e.g. 'kenney/tiny-town'.",
                    },
                    "assetType": {
                        "type": "string",
                        "enum": [
                            "sprite_2d",
                            "model_3d",
                            "audio_sfx",
                            "audio_music",
                            "ui_sprite",
                        ],
                        "description": "Asset category — must match candidate's asset_type.",
                    },
                    "licenseAcknowledged": {
                        "type": "boolean",
                        "description": "Must be true. User must accept the license first.",
                    },
                    "targetPath": {
                        "type": "string",
                        "description": "Destination folder under Assets/. Optional — sensible default per assetType.",
                    },
                    "importOptions": {
                        "type": "object",
                        "description": "Optional asset-type-specific overrides.",
                    },
                },
                "required": ["candidateId", "assetType", "licenseAcknowledged"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_imported_assets",
            "description": (
                "List assets imported through the asset pipeline in this project, "
                "with their license metadata. Read-only. Use before commercial "
                "release to audit attribution requirements (CC-BY assets need "
                "credit; CC0 does not). Reads .gladekit-asset.json sidecars."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "licenseFilter": {
                        "type": "string",
                        "enum": ["CC0-1.0", "CC-BY-4.0", "CC-BY-SA-4.0", "MIT", "any"],
                        "description": "Filter to a specific license, or 'any' (default).",
                    },
                },
                "required": [],
            },
        },
    },
]
