"""
Engine-specific tool schemas. The existing Unity catalog still lives at
`gladekit_mcp.tools` (~222 tools, kept in place to avoid churning the
OSS sync diff). New engine support lands here:

    schemas.godot — 33 Godot 4.3+ bridge tools

Selection is driven by the bridge-kind probe in `gladekit_mcp.bridge` —
the registry picks the matching schema package based on the active
bridge's `bridgeKind` field.
"""
