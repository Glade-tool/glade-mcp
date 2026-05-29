@tool
extends EditorPlugin

# EditorPlugin entry point for the GladeKit MCP Bridge.
#
# Lifecycle:
#   _enter_tree() — addon enabled OR editor reloaded a script in this addon.
#                   Start the WebSocket server.
#   _exit_tree()  — addon disabled OR script in this addon changed (Godot
#                   tears down then re-enters). Stop the server and release
#                   the socket so the next _enter_tree() can bind cleanly.

const WsServer = preload("res://addons/com.gladekit.mcp-bridge/bridge/ws_server.gd")

var _server: Node = null


func _enter_tree() -> void:
	_server = WsServer.new()
	_server.name = "GladeKitMcpBridgeServer"
	add_child(_server)
	_server.start()


func _exit_tree() -> void:
	if _server == null:
		return
	_server.stop()
	_server.queue_free()
	_server = null
