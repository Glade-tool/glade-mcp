extends RefCounted

# Explicit tool registration. Adding a new tool is two steps:
#   1. Create the tool .gd file extending i_tool.gd
#   2. Add a const + register_tool() call below
#
# We deliberately avoid scanning tools/implementations/ via DirAccess: the
# explicit list surfaces drift loudly (failing tests, missing const) instead
# of silently dropping a tool when its filename changes.

# ── Scene / Node tools (Phase 2) ───────────────────────────────────────────
const GetSceneTreeTool      = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/get_scene_tree.gd")
const GetNodeInfoTool       = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/get_node_info.gd")
const FindNodesTool         = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/find_nodes.gd")
const CreateNodeTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/create_node.gd")
const CreatePrimitive3DTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/create_primitive_3d.gd")
const DeleteNodeTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/delete_node.gd")
const RenameNodeTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/rename_node.gd")
const DuplicateNodeTool     = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/duplicate_node.gd")
const SetNodeParentTool     = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/set_node_parent.gd")
const SetNodeTransformTool  = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/set_node_transform.gd")
const SetNodeResourceTool   = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/set_node_resource.gd")

# ── Script tools (Phase 2) ─────────────────────────────────────────────────
const CreateScriptTool       = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/create_script.gd")
const ModifyScriptTool       = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/modify_script.gd")
const GetScriptContentTool   = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/get_script_content.gd")
const FindScriptsTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/find_scripts.gd")
const AttachScriptToNodeTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/attach_script_to_node.gd")

# ── Camera / Light tools (Phase 3) ─────────────────────────────────────────
const CreateCamera3DTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/camera/create_camera_3d.gd")
const CreateLightTool    = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/camera/create_light.gd")

# ── Resource tools (Phase 3 + 7) ───────────────────────────────────────────
const CreateMaterialTool      = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/resource/create_material.gd")
const SetMaterialPropertyTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/resource/set_material_property.gd")
const CreateResourceTool      = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/resource/create_resource.gd")

# ── Physics tools (Phase 3) ────────────────────────────────────────────────
const CreatePhysicsBodyTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/physics/create_physics_body.gd")

# ── Scene I/O tools (Phase 3) ──────────────────────────────────────────────
const CreateSceneTool      = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene_io/create_scene.gd")
const OpenSceneTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene_io/open_scene.gd")
const SaveSceneTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene_io/save_scene.gd")
const InstantiateSceneTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene_io/instantiate_scene.gd")

# ── Runtime / process tools (Phase 3) ──────────────────────────────────────
const GetPlayModeStateTool    = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/runtime/get_play_mode_state.gd")
const GetSelectionTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/runtime/get_selection.gd")
const GetGodotConsoleLogsTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/runtime/get_godot_console_logs.gd")
const RunProjectTool          = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/runtime/run_project.gd")
const StopProjectTool         = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/runtime/stop_project.gd")
const GetDebugOutputTool      = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/runtime/get_debug_output.gd")
const LaunchEditorTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/runtime/launch_editor.gd")

# ── UID tools (Phase 3, Godot 4.4+ only) ───────────────────────────────────
const GetUidTool            = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/uid/get_uid.gd")
const UpdateProjectUidsTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/uid/update_project_uids.gd")

# ── Signal tools (Phase 5) ─────────────────────────────────────────────────
const ConnectSignalTool         = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/signal/connect_signal.gd")
const ListSignalConnectionsTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/signal/list_signal_connections.gd")
const DisconnectSignalTool      = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/signal/disconnect_signal.gd")

# ── Project introspection tools ────────────────────────────────────────────
const GetProjectInfoTool        = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/project/get_project_info.gd")

var _tools: Dictionary = {}


func _init() -> void:
	_register_all()


func _register_all() -> void:
	# Scene / Node (11)
	register_tool(GetSceneTreeTool.new())
	register_tool(GetNodeInfoTool.new())
	register_tool(FindNodesTool.new())
	register_tool(CreateNodeTool.new())
	register_tool(CreatePrimitive3DTool.new())
	register_tool(DeleteNodeTool.new())
	register_tool(RenameNodeTool.new())
	register_tool(DuplicateNodeTool.new())
	register_tool(SetNodeParentTool.new())
	register_tool(SetNodeTransformTool.new())
	register_tool(SetNodeResourceTool.new())
	# Script (5)
	register_tool(CreateScriptTool.new())
	register_tool(ModifyScriptTool.new())
	register_tool(GetScriptContentTool.new())
	register_tool(FindScriptsTool.new())
	register_tool(AttachScriptToNodeTool.new())
	# Camera / Light (2)
	register_tool(CreateCamera3DTool.new())
	register_tool(CreateLightTool.new())
	# Resource (3) — Material has its own dedicated tool; create_resource
	# handles every other built-in Resource subclass (Mesh, Shape3D, Curve, etc.)
	register_tool(CreateMaterialTool.new())
	register_tool(SetMaterialPropertyTool.new())
	register_tool(CreateResourceTool.new())
	# Physics (1)
	register_tool(CreatePhysicsBodyTool.new())
	# Scene I/O (4)
	register_tool(CreateSceneTool.new())
	register_tool(OpenSceneTool.new())
	register_tool(SaveSceneTool.new())
	register_tool(InstantiateSceneTool.new())
	# Runtime / process (7)
	register_tool(GetPlayModeStateTool.new())
	register_tool(GetSelectionTool.new())
	register_tool(GetGodotConsoleLogsTool.new())
	register_tool(RunProjectTool.new())
	register_tool(StopProjectTool.new())
	register_tool(GetDebugOutputTool.new())
	register_tool(LaunchEditorTool.new())
	# UID (2, 4.4+)
	register_tool(GetUidTool.new())
	register_tool(UpdateProjectUidsTool.new())
	# Signal (3, Phase 5) — persistent (scene-saved) signal wiring
	register_tool(ConnectSignalTool.new())
	register_tool(ListSignalConnectionsTool.new())
	register_tool(DisconnectSignalTool.new())
	# Project introspection (1)
	register_tool(GetProjectInfoTool.new())


func register_tool(tool_instance) -> void:
	var n: String = tool_instance.tool_name
	if n.is_empty():
		push_error("[GladeKit MCP Bridge] Cannot register tool with empty name (instance: %s)" % tool_instance)
		return
	if _tools.has(n):
		push_error("[GladeKit MCP Bridge] Duplicate tool registration: '%s'" % n)
		return
	_tools[n] = tool_instance


func get_tool(tool_name: String):
	return _tools.get(tool_name, null)


func has_tool(tool_name: String) -> bool:
	return _tools.has(tool_name)


func get_tool_names() -> Array:
	var names: Array = _tools.keys()
	names.sort()
	return names


func get_tool_count() -> int:
	return _tools.size()
