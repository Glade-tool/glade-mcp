"""
Godot particle / juice tools (2 tools).

Preset-driven GPUParticles2D / GPUParticles3D scaffolding. Particles are the
cheapest, highest-impact way to make a game feel alive (impacts, pickups, fire,
smoke, trails); the presets ship tuned ParticleProcessMaterial values so the
result looks intentional without hand-authoring ~15-25 fiddly properties. The 3D
variant additionally ships a billboarded draw pass so the effect is visible
immediately (a GPUParticles3D renders nothing without one).
"""

from typing import Dict, List

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "create_particles_2d",
            "description": (
                "Add a GPUParticles2D with a fully-tuned ParticleProcessMaterial in ONE "
                "call, chosen from a preset. PREFER THIS over hand-wiring a particle "
                "material for any 'juice'/effect request — explosion on a hit, sparkles on "
                "a pickup, smoke from a chimney, fire on a torch, a trail behind a "
                "projectile. Particles draw a small white square by default (no texture "
                "needed) so the effect is visible immediately; assign a texture later for "
                "art. Presets: 'explosion' (one-shot radial burst, orange->red), 'sparkle' "
                "(gentle continuous twinkle), 'smoke' (slow rising gray puffs), 'fire' "
                "(continuous upward flame), 'trail' (world-space dots that streak behind a "
                "moving parent — parent this one to the node that moves). After it runs, "
                "call save_scene."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "preset": {
                        "type": "string",
                        "enum": ["explosion", "sparkle", "smoke", "fire", "trail"],
                        "description": "Effect preset. Default 'explosion'.",
                    },
                    "name": {
                        "type": "string",
                        "description": "Node name. Default '<Preset>Particles'.",
                    },
                    "parent_path": {
                        "type": "string",
                        "description": (
                            "Scene-relative parent. Default scene root. For the 'trail' "
                            "preset, parent it to the moving node you want it to streak behind."
                        ),
                    },
                    "position": {
                        "type": "string",
                        "description": "'x,y' initial position in pixels. Default '0,0'.",
                    },
                    "amount": {
                        "type": "integer",
                        "description": "Particle count override. Default: per-preset.",
                    },
                    "lifetime": {
                        "type": "number",
                        "description": "Seconds each particle lives. Default: per-preset.",
                    },
                    "one_shot": {
                        "type": "boolean",
                        "description": (
                            "Emit a single burst then stop. Default: true for 'explosion', false otherwise."
                        ),
                    },
                    "emitting": {
                        "type": "boolean",
                        "description": (
                            "Start emitting immediately. Default true (previews in the editor "
                            "/ fires on scene load). Set false to arm it and trigger from a "
                            "script (set emitting=true or call restart())."
                        ),
                    },
                    "color": {
                        "type": "string",
                        "description": (
                            "Override the dominant color as '#rrggbb[aa]' or 'r,g,b[,a]'. The "
                            "preset's color ramp is rebuilt as this color fading to transparent."
                        ),
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_particles_3d",
            "description": (
                "Add a GPUParticles3D with a fully-tuned ParticleProcessMaterial AND a "
                "ready-to-see draw pass in ONE call, chosen from a preset. The 3D twin of "
                "create_particles_2d — PREFER THIS over hand-wiring for any 'juice'/effect "
                "in a 3D (Node3D) scene: explosion on a hit, sparkles on a pickup, smoke "
                "from a chimney, fire on a torch, a trail behind a projectile. Unlike 2D, a "
                "GPUParticles3D renders nothing without a draw mesh, so each preset ships a "
                "small billboarded, unshaded QuadMesh that shows the per-particle color "
                "immediately; assign your own mesh/material later for art. Gravity is +Y-up "
                "and velocities are in meters (the presets handle this). Presets: 'explosion' "
                "(one-shot radial burst, orange->red), 'sparkle' (gentle continuous twinkle), "
                "'smoke' (slow rising gray puffs), 'fire' (continuous upward flame), 'trail' "
                "(world-space dots that streak behind a moving parent — parent this one to "
                "the node that moves). After it runs, call save_scene."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "preset": {
                        "type": "string",
                        "enum": ["explosion", "sparkle", "smoke", "fire", "trail"],
                        "description": "Effect preset. Default 'explosion'.",
                    },
                    "name": {
                        "type": "string",
                        "description": "Node name. Default '<Preset>Particles'.",
                    },
                    "parent_path": {
                        "type": "string",
                        "description": (
                            "Scene-relative parent. Default scene root. For the 'trail' "
                            "preset, parent it to the moving node you want it to streak behind."
                        ),
                    },
                    "position": {
                        "type": "string",
                        "description": "'x,y,z' initial position in meters. Default '0,0,0'.",
                    },
                    "amount": {
                        "type": "integer",
                        "description": "Particle count override. Default: per-preset.",
                    },
                    "lifetime": {
                        "type": "number",
                        "description": "Seconds each particle lives. Default: per-preset.",
                    },
                    "one_shot": {
                        "type": "boolean",
                        "description": (
                            "Emit a single burst then stop. Default: true for 'explosion', false otherwise."
                        ),
                    },
                    "emitting": {
                        "type": "boolean",
                        "description": (
                            "Start emitting immediately. Default true (previews in the editor "
                            "/ fires on scene load). Set false to arm it and trigger from a "
                            "script (set emitting=true or call restart())."
                        ),
                    },
                    "color": {
                        "type": "string",
                        "description": (
                            "Override the dominant color as '#rrggbb[aa]' or 'r,g,b[,a]'. The "
                            "preset's color ramp is rebuilt as this color fading to transparent."
                        ),
                    },
                },
            },
        },
    },
]
