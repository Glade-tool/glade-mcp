"""Godot asset pipeline schemas — find, import, and audit external CC0 assets.

These describe find_asset, import_asset, and list_imported_assets to MCP
clients. find_asset and import_asset resolve download URLs locally from a
bundled Kenney CC0 catalog (the orchestrator ships in `gladekit_mcp.asset_pipeline`)
— no external service is required. import_asset and list_imported_assets run
against the Godot bridge; find_asset is answered locally and has no bridge tool.

Toggle: set GLADEKIT_MCP_DISABLE_ASSET_PIPELINE=1 to suppress these tools
entirely. Useful for studios that already have their own asset pipeline and
don't want the agent reaching out to external sources.
"""

from typing import Dict, List

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "find_asset",
            "description": (
                "**Search-only — returns previewable candidates; does NOT install anything.** "
                "ALWAYS use this tool — not web search — when the user asks to find, download, "
                "search for, or import any game asset: art, sprites, 2D/3D models, audio, SFX, "
                "music, UI icons, tilesets, platformer art, character art, etc. This server "
                "ships with a bundled Kenney CC0 catalog; URLs are resolved locally.\n\n"
                "AFTER find_asset RETURNS — reply in ONE SHORT SENTENCE:\n"
                "  • Name the top match: 'Top match: <name> (<license>).'\n"
                "  • If the user's message asked to 'import it' / 'and import', ALSO add: "
                "'Want me to import it?' — then wait for confirmation.\n"
                "  • Otherwise just name the top match and stop.\n\n"
                "DO NOT claim inability to download — import_asset performs the download itself; "
                "you do not need a local file. DO NOT auto-call import_asset before the user "
                "confirms which one.\n\n"
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
                "**Downloads, installs, and configures an external asset in the Godot project.** "
                "No local file is required — the bridge fetches the asset over HTTPS from the "
                "provider's official host, extracts archives, places everything under res://, "
                "triggers a filesystem rescan so Godot imports the files, and writes a license "
                "sidecar (.gladekit-asset.json). The download URL is resolved locally from the "
                "bundled catalog; you don't and can't supply it.\n\n"
                "Use this for any candidate returned by find_asset. The candidateId fully "
                "identifies the asset.\n\n"
                "REQUIRED LICENSE GATE: licenseAcknowledged MUST be true. Set it to true only "
                "after the user has explicitly accepted the license shown in the prior "
                "find_asset result (e.g. they said 'import it', 'yes', 'go ahead')."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "candidateId": {
                        "type": "string",
                        "description": "Stable id from find_asset, e.g. 'kenney/pixel-platformer'.",
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
                        "description": "Destination folder under res://. Optional — sensible default per assetType.",
                    },
                    "importOptions": {
                        "type": "object",
                        "description": (
                            "Optional asset-type-specific overrides. Supported key: "
                            "filter ('nearest' | 'linear') for sprite_2d / ui_sprite imports. "
                            "Pass 'nearest' for PIXEL ART (keeps sprites crisp); omit or use "
                            "'linear' for smooth/vector/HD art. Sets the project's default 2D "
                            "texture filter (reported back). Other import defaults are sensible."
                        ),
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
                "List assets imported through the asset pipeline in this Godot project, with "
                "their license metadata. Read-only. Use before commercial release to audit "
                "attribution requirements (CC-BY assets need credit; CC0 does not). Reads "
                ".gladekit-asset.json sidecars under res://."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "license_filter": {
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
