extends RefCounted
## Classe utilitária estática de rede para o addon gRPC.
##
## Atua como ponto central para gerenciamento da instância gRPC (Client ou Server) via membros estáticos.

## Instância ativa do gRPC.
static var grpc: GRpcBase = null
