@tool
extends EditorPlugin
## Plugin principal para o addon gRPC.
##
## Gerencia a ativação e desativação do singleton de rede no editor.

## Chamado quando o plugin é ativado. Adiciona o singleton 'Network'.
func _enable_plugin() -> void:
	var network_path: String = "res://addons/grpc/network/network.gd"
	self.add_autoload_singleton("Network", network_path)

## Chamado quando o plugin é desativado. Remove o singleton 'Network'.
func _disable_plugin() -> void:
	self.remove_autoload_singleton("Network")
