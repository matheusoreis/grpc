extends Node
## Singleton de rede para o addon gRPC.
##
## Atua como o ponto central para processamento de pacotes e gerenciamento da instância gRPC.

## Instância ativa do gRPC (Client ou Server).
var grpc: GRpcBase = null
## Tempo máximo de processamento por frame em milissegundos.
var timeout_ms: int = 0

## Processa a lógica de rede a cada frame se houver uma instância ativa.
func _process(_delta: float) -> void:
	if grpc:
		grpc.process(timeout_ms)
