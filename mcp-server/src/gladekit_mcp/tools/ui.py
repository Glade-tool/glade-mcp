"""
UI category tools — Canvas, UI elements, TextMeshPro, event system, layout groups.
"""

from typing import Dict, List

CATEGORY = {
    "name": "ui",
    "display_name": "UI (Canvas & Elements)",
    "keywords": [
        "ui",
        "canvas",
        "button",
        "text",
        "image",
        "slider",
        "scroll",
        "panel",
        "hud",
        "menu",
        "textmeshpro",
        "tmp",
        "layout",
        "event system",
        "toggle",
        "dropdown",
        "input field",
    ],
}

TOOLS: List[Dict] = [
    {
        "type": "function",
        "function": {
            "name": "create_canvas",
            "description": "Create a Canvas with scaler and raycaster. Requires TextMeshPro (auto-installed if missing).",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "renderMode": {
                        "type": "string",
                        "enum": [
                            "ScreenSpaceOverlay",
                            "ScreenSpaceCamera",
                            "WorldSpace",
                        ],
                    },
                    "cameraPath": {"type": "string"},
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_ui_element",
            "description": "Create a UI element (Panel, Text/TMP, Image, Button, Slider, Toggle, Dropdown, InputField, ScrollView, LayoutGroup, etc.). Requires TextMeshPro. Always specify contrasting colors (white text on dark panels, dark text on light panels). For health bars, use type='Filled' with fillMethod='Horizontal'.",
            "parameters": {
                "type": "object",
                "properties": {
                    "elementType": {
                        "type": "string",
                        "enum": [
                            "Panel",
                            "Text",
                            "Image",
                            "Button",
                            "Slider",
                            "Toggle",
                            "Dropdown",
                            "TMP_Dropdown",
                            "InputField",
                            "TMP_InputField",
                            "ScrollView",
                            "ScrollRect",
                            "Scrollbar",
                            "RawImage",
                            "CanvasGroup",
                            "HorizontalLayoutGroup",
                            "VerticalLayoutGroup",
                            "GridLayoutGroup",
                            "Mask",
                            "RectMask2D",
                            "TMP",
                            "TextMeshPro",
                            "TextMeshProUGUI",
                        ],
                    },
                    "name": {"type": "string"},
                    "parentPath": {"type": "string"},
                    "text": {"type": "string"},
                    "color": {"type": "string"},
                    "fontSize": {"type": "number"},
                    "alignment": {"type": "string"},
                    "size": {"type": "string"},
                    "anchoredPosition": {"type": "string"},
                    "isOn": {
                        "type": "boolean",
                        "description": "Toggle-specific: initial state",
                    },
                    "toggleGroupPath": {
                        "type": "string",
                        "description": "Toggle-specific: path to ToggleGroup GameObject",
                    },
                    "options": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Dropdown-specific: list of option strings",
                    },
                    "placeholder": {
                        "type": "string",
                        "description": "InputField-specific: placeholder text",
                    },
                    "contentType": {
                        "type": "string",
                        "enum": [
                            "Standard",
                            "Autocorrected",
                            "IntegerNumber",
                            "DecimalNumber",
                            "Alphanumeric",
                            "Name",
                            "EmailAddress",
                            "Password",
                            "Pin",
                            "Custom",
                        ],
                        "description": "InputField-specific: content type",
                    },
                    "characterLimit": {
                        "type": "integer",
                        "description": "InputField-specific: max character count",
                    },
                    "horizontal": {
                        "type": "boolean",
                        "description": "ScrollRect-specific: enable horizontal scrolling",
                    },
                    "vertical": {
                        "type": "boolean",
                        "description": "ScrollRect-specific: enable vertical scrolling",
                    },
                    "direction": {
                        "type": "string",
                        "enum": [
                            "LeftToRight",
                            "RightToLeft",
                            "BottomToTop",
                            "TopToBottom",
                        ],
                        "description": "Scrollbar-specific: scrollbar direction",
                    },
                    "texturePath": {
                        "type": "string",
                        "description": "RawImage-specific: path to texture asset",
                    },
                    "alpha": {
                        "type": "number",
                        "description": "CanvasGroup-specific: alpha value 0-1",
                    },
                    "interactable": {
                        "type": "boolean",
                        "description": "CanvasGroup-specific: whether group is interactable",
                    },
                    "blocksRaycasts": {
                        "type": "boolean",
                        "description": "CanvasGroup-specific: whether group blocks raycasts",
                    },
                    "spacing": {
                        "type": "number",
                        "description": "LayoutGroup-specific: spacing between children",
                    },
                    "padding": {
                        "type": "string",
                        "description": "LayoutGroup-specific: padding as 'left,right,top,bottom'",
                    },
                    "cellSize": {
                        "type": "string",
                        "description": "GridLayoutGroup-specific: cell size as 'width,height'",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "import_tmp_essential_resources",
            "description": "Import TextMeshPro Essential Resources if not already present (checks Assets/TextMesh Pro/Resources). TMP package presence in Unity context does not mean Essential Resources are imported — trust this tool's response, not the context.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_ui_properties",
            "description": "Update UI element properties (TMP text, Image, Button, Slider, Toggle, Dropdown, InputField, LayoutGroups, RectTransform, etc.). Always specify contrasting text/background colors. For health bars: type='Filled', fillMethod='Horizontal', fillOrigin=0. HUD anchors: anchorMin='0,1', anchorMax='0,1'.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Path to the UI element GameObject",
                    },
                    "size": {
                        "type": "string",
                        "description": "RectTransform: size as 'width,height'",
                    },
                    "anchoredPosition": {
                        "type": "string",
                        "description": "RectTransform: position as 'x,y'",
                    },
                    "anchorMin": {
                        "type": "string",
                        "description": "RectTransform: anchor min as 'x,y'",
                    },
                    "anchorMax": {
                        "type": "string",
                        "description": "RectTransform: anchor max as 'x,y'",
                    },
                    "pivot": {
                        "type": "string",
                        "description": "RectTransform: pivot as 'x,y'",
                    },
                    "text": {
                        "type": "string",
                        "description": "Text/TextMeshPro: text content",
                    },
                    "fontSize": {
                        "type": "integer",
                        "description": "Text/TextMeshPro: font size",
                    },
                    "color": {
                        "type": "string",
                        "description": "Text/Image/RawImage: color as 'r,g,b,a'",
                    },
                    "alignment": {
                        "type": "string",
                        "description": "Text/TextMeshPro: text alignment",
                    },
                    "spritePath": {
                        "type": "string",
                        "description": "Image: path to sprite asset",
                    },
                    "fillAmount": {
                        "type": "number",
                        "description": "Image: fill amount 0-1 (for Filled type health bars)",
                    },
                    "imageType": {
                        "type": "string",
                        "enum": ["Simple", "Sliced", "Tiled", "Filled"],
                        "description": "Image: image type (use 'Filled' for health bars)",
                    },
                    "fillMethod": {
                        "type": "string",
                        "enum": [
                            "Horizontal",
                            "Vertical",
                            "Radial90",
                            "Radial180",
                            "Radial360",
                        ],
                        "description": "Image: fill method (for Filled type, use 'Horizontal' for health bars)",
                    },
                    "fillOrigin": {
                        "type": "integer",
                        "description": "Image: fill origin (0=Left, 1=Right for Horizontal; 0=Bottom, 1=Top for Vertical; 0-3 for Radial)",
                    },
                    "preserveAspect": {
                        "type": "boolean",
                        "description": "Image: preserve aspect ratio",
                    },
                    "raycastTarget": {
                        "type": "boolean",
                        "description": "Image: whether to receive raycasts",
                    },
                    "interactable": {
                        "type": "boolean",
                        "description": "Button/CanvasGroup: interactable state",
                    },
                    "minValue": {
                        "type": "number",
                        "description": "Slider: minimum value",
                    },
                    "maxValue": {
                        "type": "number",
                        "description": "Slider: maximum value",
                    },
                    "value": {
                        "type": "number",
                        "description": "Slider/Scrollbar/Dropdown: current value",
                    },
                    "isOn": {"type": "boolean", "description": "Toggle: checked state"},
                    "toggleGroupPath": {
                        "type": "string",
                        "description": "Toggle: path to ToggleGroup GameObject",
                    },
                    "options": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Dropdown: list of option strings",
                    },
                    "placeholder": {
                        "type": "string",
                        "description": "InputField: placeholder text",
                    },
                    "contentType": {
                        "type": "string",
                        "description": "InputField: content type enum",
                    },
                    "characterLimit": {
                        "type": "integer",
                        "description": "InputField: max character count",
                    },
                    "lineType": {
                        "type": "string",
                        "enum": ["SingleLine", "MultiLineNewline", "MultiLineSubmit"],
                        "description": "InputField: line type",
                    },
                    "contentPath": {
                        "type": "string",
                        "description": "ScrollRect: path to content GameObject",
                    },
                    "viewportPath": {
                        "type": "string",
                        "description": "ScrollRect: path to viewport GameObject",
                    },
                    "horizontal": {
                        "type": "boolean",
                        "description": "ScrollRect: enable horizontal scrolling",
                    },
                    "vertical": {
                        "type": "boolean",
                        "description": "ScrollRect: enable vertical scrolling",
                    },
                    "movementType": {
                        "type": "string",
                        "enum": ["Unrestricted", "Elastic", "Clamped"],
                        "description": "ScrollRect: movement type",
                    },
                    "direction": {
                        "type": "string",
                        "description": "Scrollbar: direction enum",
                    },
                    "numberOfSteps": {
                        "type": "integer",
                        "description": "Scrollbar: number of steps",
                    },
                    "texturePath": {
                        "type": "string",
                        "description": "RawImage: path to texture asset",
                    },
                    "uvRect": {
                        "type": "string",
                        "description": "RawImage: UV rect as 'x,y,width,height'",
                    },
                    "alpha": {
                        "type": "number",
                        "description": "CanvasGroup: alpha value 0-1",
                    },
                    "blocksRaycasts": {
                        "type": "boolean",
                        "description": "CanvasGroup: blocks raycasts",
                    },
                    "ignoreParentGroups": {
                        "type": "boolean",
                        "description": "CanvasGroup: ignore parent groups",
                    },
                    "spacing": {
                        "type": "number",
                        "description": "LayoutGroup: spacing (for GridLayoutGroup use 'x,y' string)",
                    },
                    "padding": {
                        "type": "string",
                        "description": "LayoutGroup: padding as 'left,right,top,bottom'",
                    },
                    "childAlignment": {
                        "type": "string",
                        "enum": [
                            "UpperLeft",
                            "UpperCenter",
                            "UpperRight",
                            "MiddleLeft",
                            "MiddleCenter",
                            "MiddleRight",
                            "LowerLeft",
                            "LowerCenter",
                            "LowerRight",
                        ],
                        "description": "LayoutGroup: child alignment",
                    },
                    "childControlWidth": {
                        "type": "boolean",
                        "description": "LayoutGroup: control child width",
                    },
                    "childControlHeight": {
                        "type": "boolean",
                        "description": "LayoutGroup: control child height",
                    },
                    "childForceExpandWidth": {
                        "type": "boolean",
                        "description": "LayoutGroup: force expand width",
                    },
                    "childForceExpandHeight": {
                        "type": "boolean",
                        "description": "LayoutGroup: force expand height",
                    },
                    "cellSize": {
                        "type": "string",
                        "description": "GridLayoutGroup: cell size as 'width,height'",
                    },
                    "startCorner": {
                        "type": "string",
                        "enum": ["UpperLeft", "UpperRight", "LowerLeft", "LowerRight"],
                        "description": "GridLayoutGroup: start corner",
                    },
                    "startAxis": {
                        "type": "string",
                        "enum": ["Horizontal", "Vertical"],
                        "description": "GridLayoutGroup: start axis",
                    },
                    "constraint": {
                        "type": "string",
                        "enum": ["Flexible", "FixedColumnCount", "FixedRowCount"],
                        "description": "GridLayoutGroup: constraint type",
                    },
                    "constraintCount": {
                        "type": "integer",
                        "description": "GridLayoutGroup: constraint count",
                    },
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "create_event_system",
            "description": "Create an EventSystem if one does not exist.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_ui_hierarchy",
            "description": "List all Canvas objects and their UI element hierarchy. Use this FIRST when working with UI to understand what exists. Returns all Canvas objects with their children UI elements (Text, Image, Button, etc.) in a hierarchical structure.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_ui_element_info",
            "description": "Get detailed UI-specific information about a UI element including component type, all UI properties, and event handlers. Returns component-specific properties (e.g., Button interactable, Dropdown options, InputField text, etc.).",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Path to the UI element GameObject",
                    }
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "find_ui_elements_by_type",
            "description": "Find all UI elements of a specific component type in the scene. Returns array of GameObject paths.",
            "parameters": {
                "type": "object",
                "properties": {
                    "elementType": {
                        "type": "string",
                        "enum": [
                            "Button",
                            "Text",
                            "Image",
                            "Slider",
                            "Toggle",
                            "Dropdown",
                            "TMP_Dropdown",
                            "InputField",
                            "TMP_InputField",
                            "ScrollRect",
                            "Scrollbar",
                            "RawImage",
                            "CanvasGroup",
                            "HorizontalLayoutGroup",
                            "VerticalLayoutGroup",
                            "GridLayoutGroup",
                            "Canvas",
                            "EventSystem",
                        ],
                        "description": "Type of UI component to find",
                    },
                    "canvasPath": {
                        "type": "string",
                        "description": "Optional: Limit search to specific Canvas",
                    },
                },
                "required": ["elementType"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "check_ui_element_exists",
            "description": "Check if a UI element exists at the given path. Verifies both GameObject existence and presence of RectTransform (UI elements must have RectTransform).",
            "parameters": {
                "type": "object",
                "properties": {
                    "elementPath": {
                        "type": "string",
                        "description": "Path to the UI element",
                    }
                },
                "required": ["elementPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_ui_event_handlers",
            "description": "Get information about all event handlers wired to a UI element (onClick, onValueChanged, onSubmit, etc.). Returns event type, target GameObject, method name, and argument count.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Path to the UI element",
                    }
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_ui_event",
            "description": "Wire a UI event to a method. Creates a UnityEvent connection. For runtime events, creates a script component if needed. Note: This creates persistent listeners that work in both editor and runtime.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {
                        "type": "string",
                        "description": "Path to the UI element",
                    },
                    "eventType": {
                        "type": "string",
                        "enum": [
                            "onClick",
                            "onValueChanged",
                            "onEndEdit",
                            "onSubmit",
                            "onValueChangedInt",
                            "onSelect",
                            "onDeselect",
                        ],
                        "description": "Type of event to wire",
                    },
                    "targetGameObjectPath": {
                        "type": "string",
                        "description": "Path to GameObject with the target method",
                    },
                    "methodName": {
                        "type": "string",
                        "description": "Name of the method to call",
                    },
                    "componentType": {
                        "type": "string",
                        "description": "Optional: Component type containing the method (if not provided, searches all components)",
                    },
                },
                "required": [
                    "gameObjectPath",
                    "eventType",
                    "targetGameObjectPath",
                    "methodName",
                ],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "remove_ui_event",
            "description": "Remove event handlers from a UI element. Can remove all handlers of a type or a specific handler.",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {"type": "string"},
                    "eventType": {
                        "type": "string",
                        "enum": [
                            "onClick",
                            "onValueChanged",
                            "onEndEdit",
                            "onSubmit",
                            "onValueChangedInt",
                            "onSelect",
                            "onDeselect",
                        ],
                    },
                    "removeAll": {
                        "type": "boolean",
                        "description": "If true, remove all handlers of this event type. If false, remove specific handler.",
                        "default": True,
                    },
                    "targetGameObjectPath": {
                        "type": "string",
                        "description": "Required if removeAll=false",
                    },
                    "methodName": {
                        "type": "string",
                        "description": "Required if removeAll=false",
                    },
                },
                "required": ["gameObjectPath", "eventType"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_layout_group_properties",
            "description": "Set properties on layout group components (HorizontalLayoutGroup, VerticalLayoutGroup, GridLayoutGroup).",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {"type": "string"},
                    "spacing": {
                        "type": "number",
                        "description": "For GridLayoutGroup, use 'x,y' string format",
                    },
                    "padding": {
                        "type": "string",
                        "description": "RectOffset as 'left,right,top,bottom'",
                    },
                    "childAlignment": {
                        "type": "string",
                        "enum": [
                            "UpperLeft",
                            "UpperCenter",
                            "UpperRight",
                            "MiddleLeft",
                            "MiddleCenter",
                            "MiddleRight",
                            "LowerLeft",
                            "LowerCenter",
                            "LowerRight",
                        ],
                    },
                    "childControlWidth": {"type": "boolean"},
                    "childControlHeight": {"type": "boolean"},
                    "childForceExpandWidth": {"type": "boolean"},
                    "childForceExpandHeight": {"type": "boolean"},
                    "cellSize": {
                        "type": "string",
                        "description": "For GridLayoutGroup: 'width,height'",
                    },
                    "startCorner": {
                        "type": "string",
                        "enum": ["UpperLeft", "UpperRight", "LowerLeft", "LowerRight"],
                    },
                    "startAxis": {"type": "string", "enum": ["Horizontal", "Vertical"]},
                    "constraint": {
                        "type": "string",
                        "enum": ["Flexible", "FixedColumnCount", "FixedRowCount"],
                    },
                    "constraintCount": {"type": "integer"},
                },
                "required": ["gameObjectPath"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_canvasgroup_properties",
            "description": "Set properties on a CanvasGroup component (alpha, interactable, blocksRaycasts, ignoreParentGroups).",
            "parameters": {
                "type": "object",
                "properties": {
                    "gameObjectPath": {"type": "string"},
                    "alpha": {"type": "number", "description": "Alpha value 0-1"},
                    "interactable": {"type": "boolean"},
                    "blocksRaycasts": {"type": "boolean"},
                    "ignoreParentGroups": {"type": "boolean"},
                },
                "required": ["gameObjectPath"],
            },
        },
    },
]
