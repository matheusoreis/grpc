## Classe base para o sistema gRPC no Godot 4.5.1.
##
## [b]GRpcBase[/b] é o núcleo do sistema de chamadas remotas. Ela gerencia o registro de métodos, 
## a validação de tipos de argumentos e o roteamento de pacotes entre peers.
##
## [b]Nota:[/b] Esta classe não deve ser instanciada diretamente. Use [GRpcClient] ou [GRpcServer].
class_name GRpcBase
extends RefCounted

## Estrutura interna para armazenar informações de métodos registrados.
class GRpcMethodEntry:
	## O [Callable] que será executado remotamente.
	var function_callable: Callable
	## Lista de tipos de argumentos ([code]TYPE_*[/code]) esperados pela função.
	var argument_types: Array[int]

	func _init(p_function_callable: Callable, p_argument_types: Array[int]) -> void:
		self.function_callable = p_function_callable
		self.argument_types = p_argument_types

## Tipos de mensagens suportadas pelo protocolo gRPC.
enum Type {
	## Execução simples sem retorno de dados.
	EXEC,
	## Execução que aguarda um resultado ([code]await[/code]).
	INVOKE,
	## Pacote contendo o resultado de uma operação [code]INVOKE[/code].
	RESULT,
}

## Dicionário interno para busca rápida de métodos registrados.
var _lookup: Dictionary[int, GRpcMethodEntry] = {}
## Lista de tarefas ([GRpcTask]) aguardando resposta.
var _tasks: Array[GRpcTask] = []
## Pilha de índices disponíveis no array de tarefas para otimização [i]O(1)[/i].
var _free_task_indices: Array[int] = []
## Quantidade máxima de tarefas simultâneas permitidas.
var _max_tasks: int = 2048

## Construtor da classe. Define o limite de tarefas e prepara o pool de índices.
func _init(p_max_tasks: int = 2048) -> void:
	self._max_tasks = p_max_tasks
	self._tasks.resize(p_max_tasks)
	self._free_task_indices.resize(p_max_tasks)
	for i in range(p_max_tasks):
		self._free_task_indices[i] = (p_max_tasks - 1) - i

## Registra uma lista de funções para serem chamadas remotamente.
## [br][br]
## [b]p_scope_name[/b]: Nome do escopo (ex: "Player").[br]
## [b]p_remote_functions[/b]: Array de [Callable] contendo as funções.
func register(p_scope_name: StringName, p_remote_functions: Array[Callable]) -> void:
	for function_callable in p_remote_functions:
		var function_name: StringName = function_callable.get_method()
		if function_name == &"<anonymous lambda>":
			push_error("[gRPC] Lambdas não são permitidas.")
			continue

		var function_id: int = str(p_scope_name, ".", function_name).hash()
		if self._lookup.has(function_id):
			push_error("[gRPC] Conflito de ID para %s.%s." % [p_scope_name, function_name])
			continue

		var argument_types: Array[int] = self._extract_argument_types(function_callable.get_object(), function_name)
		self._lookup[function_id] = GRpcMethodEntry.new(function_callable, argument_types)

## Remove o registro de funções de um escopo.
func unregister(p_scope_name: StringName, p_remote_functions: Array[Callable]) -> void:
	for function_callable in p_remote_functions:
		var function_id: int = str(p_scope_name, ".", function_callable.get_method()).hash()
		self._lookup.erase(function_id)

## [b]Interno:[/b] Processa os dados brutos recebidos da rede.
func _process_packet(p_sender_id: int, p_packet_buffer: PackedByteArray, p_channel_id: int) -> void:
	var packet_data: Variant = bytes_to_var(p_packet_buffer)
	if typeof(packet_data) != TYPE_ARRAY:
		return

	var packet_array: Array = packet_data as Array
	if packet_array.is_empty() or typeof(packet_array[0]) != TYPE_INT:
		return

	var message_type: int = packet_array[0]
	match message_type:
		Type.EXEC:
			self._handle_exec(p_sender_id, packet_array)
		Type.INVOKE:
			self._handle_invoke(p_sender_id, packet_array, p_channel_id)
		Type.RESULT:
			self._handle_result(packet_array)

## [b]Interno:[/b] Executa uma função local solicitada remotamente via [code]EXEC[/code].
func _handle_exec(p_sender_id: int, p_packet: Array) -> void:
	if p_packet.size() < 3: return
	
	var function_id: int = p_packet[1]
	var arguments: Array = p_packet[2]

	var method_entry: GRpcMethodEntry = self._lookup.get(function_id)
	if method_entry == null:
		push_error("[gRPC] Peer %d tentou EXEC em função não registrada." % p_sender_id)
		return

	if not self._validate_arguments(method_entry.argument_types, arguments):
		push_error("[gRPC] Argumentos inválidos para EXEC de Peer %d." % p_sender_id)
		return

	method_entry.function_callable.callv(arguments)

## [b]Interno:[/b] Executa uma função local e envia o resultado de volta (INVOKE).
func _handle_invoke(p_sender_id: int, p_packet: Array, p_channel_id: int) -> void:
	if p_packet.size() < 4: return

	var function_id: int = p_packet[1]
	var arguments: Array = p_packet[2]
	var task_id: int = p_packet[3]
	
	var method_entry: GRpcMethodEntry = self._lookup.get(function_id)
	if method_entry == null or not self._validate_arguments(method_entry.argument_types, arguments):
		return

	var result_value: Variant = await method_entry.function_callable.callv(arguments)
	self._send(p_sender_id, [Type.RESULT, result_value, task_id], p_channel_id)

## [b]Interno:[/b] Recebe o resultado de uma tarefa pendente.
func _handle_result(p_packet: Array) -> void:
	if p_packet.size() < 3: return
	
	var return_value: Variant = p_packet[1]
	var task_id: int = p_packet[2]
	
	if task_id < 0 or task_id >= self._max_tasks:
		return

	var pending_task: GRpcTask = self._tasks[task_id]
	if pending_task:
		pending_task.done.emit(return_value)

## [b]Virtual:[/b] Envia dados brutos. Deve ser implementado pelas classes filhas.
func _send_raw(_p_peer_id: int, _p_data: PackedByteArray, _p_channel_id: int) -> void:
	pass

## [b]Interno:[/b] Serializa e envia um pacote formatado.
func _send(p_peer_id: int, p_packet_array: Array, p_channel_id: int) -> void:
	self._send_raw(p_peer_id, var_to_bytes(p_packet_array), p_channel_id)

## [b]Interno:[/b] Reserva um slot de tarefa no pool.
func _reserve_task_slot() -> int:
	return self._free_task_indices.pop_back() if not self._free_task_indices.is_empty() else -1

## [b]Interno:[/b] Libera um slot de tarefa de volta para o pool.
func _release_task_slot(p_task_id: int) -> void:
	self._tasks[p_task_id] = null
	self._free_task_indices.push_back(p_task_id)

## [b]Interno:[/b] Analisa os tipos de argumentos de uma função local.
func _extract_argument_types(p_target_object: Object, p_function_name: StringName) -> Array[int]:
	var methods: Array[Dictionary] = p_target_object.get_method_list().filter(
		func(m): return m["name"] == p_function_name
	)
	
	if methods.is_empty():
		return []
		
	var args: Array = methods[0]["args"]
	var types: Array[int] = []
	types.resize(args.size())
	for i in range(args.size()):
		types[i] = args[i]["type"]
	return types

## [b]Interno:[/b] Valida se os argumentos recebidos batem com a assinatura da função.
func _validate_arguments(p_expected_types: Array[int], p_provided_arguments: Array) -> bool:
	if p_expected_types.size() != p_provided_arguments.size():
		return false
	
	for i in range(p_expected_types.size()):
		if typeof(p_provided_arguments[i]) != p_expected_types[i]:
			return false
	return true
