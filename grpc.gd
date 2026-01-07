@tool
extends EditorPlugin


func _enable_plugin() -> void:
	var network_path: String = "res://addons/grpc/network/network.gd"
	self.add_autoload_singleton("Network", network_path)


func _disable_plugin() -> void:
	self.remove_autoload_singleton("Network")
