"""
Godot UI / Control tools (6 tools, v0.5.0).

Built around three pieces of Control-tree convenience the agent otherwise
discovers the hard way:

  * create_control auto-wraps in a CanvasLayer when the scene root is a 3D
    node (the most common "I added a Button and it doesn't appear" trap).
  * set_control_anchors takes a named preset (matches the editor's Layout
    menu), so the agent never has to remember the numeric enum.
  * set_control_text picks the right text property by class
    (Button.text vs AcceptDialog.dialog_text).

list_ui_hierarchy is the read-only counterpart — get_scene_tree filtered to
Control nodes with UI-relevant fields (size, position, anchor preset, text).
"""

from typing import Dict, List

# Anchor preset enum values — kept here so the schema can advertise them in
# the description without the agent having to call list_ui_hierarchy first
# to discover names. Mirror of the PRESETS dict in
# godot-bridge/.../tools/implementations/ui/set_control_anchors.gd.
_ANCHOR_PRESETS = [
    "top_left",
    "top_right",
    "bottom_left",
    "bottom_right",
    "center_left",
    "center_top",
    "center_right",
    "center_bottom",
    "center",
    "left_wide",
    "top_wide",
    "right_wide",
    "bottom_wide",
    "vcenter_wide",
    "hcenter_wide",
    "full_rect",
]

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "create_control",
            "description": (
                "Create a UI-tree node (Button, Label, container, dialog, etc.) and "
                "add it to the edited scene. Accepts BOTH Control subclasses and "
                "Window-based popup dialogs (AcceptDialog, ConfirmationDialog, "
                "FileDialog, Popup, PopupMenu, PopupPanel) — both are 'UI nodes' "
                "even though Window is technically Viewport in the class tree. "
                "Auto-wraps Controls in a CanvasLayer named 'UI' when the scene "
                "root is a 3D/2D node (Window dialogs are NOT wrapped; they are "
                "their own popup viewport). Supports one-shot anchor preset and "
                "text via the `anchor_preset` and `text` args (saves follow-up "
                "set_control_anchors / set_control_text round-trips). For non-UI "
                "nodes use create_node."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "type": {
                        "type": "string",
                        "description": (
                            "UI node class (PascalCase). Control subclasses: Button, Label, "
                            "Panel, ColorRect, TextureRect, LineEdit, TextEdit, RichTextLabel, "
                            "HBoxContainer, VBoxContainer, GridContainer, MarginContainer, "
                            "CenterContainer, PanelContainer, ScrollContainer, TabContainer, "
                            "CheckBox, CheckButton. Window popup dialogs: AcceptDialog, "
                            "ConfirmationDialog, FileDialog, Popup, PopupMenu, PopupPanel."
                        ),
                    },
                    "name": {
                        "type": "string",
                        "description": "Node name. Default: <type>.",
                    },
                    "parent_path": {
                        "type": "string",
                        "description": (
                            "Scene-relative parent. Default: scene root (with CanvasLayer "
                            "auto-wrap when root isn't a Control host)."
                        ),
                    },
                    "text": {
                        "type": "string",
                        "description": (
                            "Optional initial text for text-bearing Controls (Button, Label, "
                            "LineEdit, TextEdit, RichTextLabel, CheckBox, CheckButton, "
                            "AcceptDialog/...). Ignored on classes without a text property — "
                            "the response's `text_applied` flag confirms."
                        ),
                    },
                    "anchor_preset": {
                        "type": "string",
                        "description": "Optional one-shot anchor preset applied after creation.",
                        "enum": _ANCHOR_PRESETS,
                    },
                    "auto_canvas_layer": {
                        "type": "boolean",
                        "description": (
                            "Wrap in a CanvasLayer named 'UI' when the resolved parent is the "
                            "scene root AND the root is not a Control / CanvasLayer / SubViewport. "
                            "Default true. Set false to opt out (you handle wrapping yourself)."
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
            "name": "set_control_anchors",
            "description": (
                "Apply one of Godot's built-in anchor presets to a Control. Mirrors the "
                "editor's Layout > Anchors menu. Default behavior recomputes offsets so "
                "the Control snaps to the preset; pass keep_offsets=true to preserve "
                "current offsets while re-anchoring (rare)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "node_path": {
                        "type": "string",
                        "description": "Scene-relative path to the target Control.",
                    },
                    "preset": {
                        "type": "string",
                        "description": (
                            "Anchor preset. full_rect makes the Control fill its parent; "
                            "center centers it; *_wide stretches along one axis."
                        ),
                        "enum": _ANCHOR_PRESETS,
                    },
                    "keep_offsets": {
                        "type": "boolean",
                        "description": "Preserve current offsets when changing anchors. Default false.",
                    },
                },
                "required": ["node_path", "preset"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_control_text",
            "description": (
                "Set the text on a text-bearing UI node. Picks the right property "
                "by class (Button/Label/LineEdit/TextEdit/RichTextLabel/CheckBox use "
                "`text`; AcceptDialog/ConfirmationDialog/FileDialog use `dialog_text`). "
                "Accepts both Control and Window subclasses. Errors with a useful hint "
                "on classes without a text property (e.g. ColorRect — use a child Label)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "node_path": {
                        "type": "string",
                        "description": "Scene-relative path to the target UI node.",
                    },
                    "text": {
                        "type": "string",
                        "description": 'New text. Pass "" to clear.',
                    },
                },
                "required": ["node_path", "text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_control_size",
            "description": (
                "Update a Control's size and/or custom_minimum_size. Pass only the "
                "dimensions you want to change. If the Control's anchors stretch it "
                "(e.g. full_rect, left_wide), `size` is recomputed on the next layout "
                "pass — the response includes a `note` flagging this so the agent "
                "can re-anchor or use custom_minimum_size instead."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "node_path": {
                        "type": "string",
                        "description": "Scene-relative path to the target Control.",
                    },
                    "width": {"type": "number", "description": "New size.x. Omit to leave unchanged."},
                    "height": {"type": "number", "description": "New size.y. Omit to leave unchanged."},
                    "min_width": {
                        "type": "number",
                        "description": "New custom_minimum_size.x. Omit to leave unchanged.",
                    },
                    "min_height": {
                        "type": "number",
                        "description": "New custom_minimum_size.y. Omit to leave unchanged.",
                    },
                },
                "required": ["node_path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_ui_hierarchy",
            "description": (
                "Read-only Control-tree walk of the edited scene. Like get_scene_tree "
                "filtered to Control nodes, with UI-relevant fields per element: type, "
                "size, position, anchor_preset (detected from current anchors, or "
                "'custom' if no built-in preset matches), text (when present), visible. "
                "Use before modifying UI to orient on what exists."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "root_path": {
                        "type": "string",
                        "description": "Scene-relative root for the walk. Default: scene root.",
                    },
                    "include_text": {
                        "type": "boolean",
                        "description": "Include text on text-bearing Controls. Default true.",
                    },
                    "max_elements": {
                        "type": "integer",
                        "description": "Cap on returned elements. Default 200, max 1000.",
                    },
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_theme",
            "description": (
                "Create an empty Theme.tres resource, optionally inheriting another "
                "theme's contents via base_theme (copied at creation; subsequent edits "
                "don't propagate). Assign the result to a Control's `theme` property "
                "via set_node_resource. Property setting (colors, fonts, styleboxes) "
                "is not yet exposed — edit theme overrides in the Godot editor for now."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "res:// path for the .tres file. Auto-appends .tres if no extension.",
                    },
                    "base_theme": {
                        "type": "string",
                        "description": (
                            "Optional res:// path to a parent Theme — its contents are "
                            "merged into the new theme at creation time."
                        ),
                    },
                },
                "required": ["path"],
            },
        },
    },
]
