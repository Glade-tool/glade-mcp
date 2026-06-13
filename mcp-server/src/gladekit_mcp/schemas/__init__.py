"""
Engine-specific tool schemas. The existing Unity catalog still lives at
`gladekit_mcp.tools` (~235 tools, kept in place to avoid churning the
OSS sync diff). New engine support lands here:

    schemas.godot — 63 Godot 4.3+ tool schemas

Selection is driven by the bridge-kind probe in `gladekit_mcp.bridge` —
the registry picks the matching schema package based on the active
bridge's `bridgeKind` field.
"""
