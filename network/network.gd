extends Node


var grpc: GRpcBase = null
var timeout_ms: int = 0


func _process(_delta: float) -> void:
	if grpc:
		grpc.process(timeout_ms)
