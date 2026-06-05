# `assets/`

Public-facing brand assets and documentation media for the project.

| File | Purpose |
|---|---|
| `icon.png` | Project icon. Used by the [Godot Asset Library](https://godotengine.org/asset-library/) listing and any README badge that needs a square brand mark. 512×512 PNG. |
| `screenshots/` | Documentation screenshots referenced from the README and from the Asset Library listing's preview slots. |

Everything here is **distribution-side**: nothing in this folder ships inside the addon zip or the PyPI package — those are built from `godot-bridge/addons/com.gladekit.mcp-bridge/` and `mcp-server/` respectively. Anything in `assets/` is for the GitHub repo browsing experience and the Asset Library listing.

When referencing these files from a README, prefer **absolute GitHub raw URLs** (`https://raw.githubusercontent.com/Glade-tool/glade-mcp/main/assets/...`) over relative paths. Relative paths work on github.com but don't render on PyPI's project page, and PyPI is the primary audience for `mcp-server/README.md`.
