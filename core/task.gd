extends RefCounted
## Representa uma tarefa assíncrona de RPC.
##
## Utilizada internamente para gerenciar o retorno de chamadas INVOKE.
class_name GRpcTask

## Emitido quando a tarefa é concluída e o resultado é recebido.
@warning_ignore("unused_signal")
signal done(value: Variant)
