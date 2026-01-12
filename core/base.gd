## Base class for the RPC (ERPC) system.
##
## This class provides the foundational logic for registering functions,
## validating arguments, and processing packets. It is not meant to be used directly,
## use [RpcClient] or [RpcServer] instead.
class_name RpcBase
extends RefCounted

## Internal task class to await for RPC results.
class RpcTask:
	## Emitted when the task is completed with a return value.
	signal done(value: Variant)

## Internal struct to hold registered method info.
class RpcMethodEntry:
	var function_callable: Callable
	var argument_types: Array[int]

	func _init(function_callable: Callable, argument_types: Array[int]) -> void:
		self.function_callable = function_callable
		self.argument_types = argument_types

## RPC Message Types.
enum Type {
	## Execute without return.
	EXEC,
	## Execute and await return.
	INVOKE,
	## Return value from INVOKE.
	RESULT,
}

## Dictionary mapping ID -> RpcMethodEntry.
var _lookup: Dictionary[int, RpcMethodEntry] = {}
## Array of active or pooled tasks.
var _tasks: Array[RpcTask] = []
## Stack of free indices in the _tasks array.
var _free_task_indices: Array[int] = []
## Maximum concurrent tasks allowed.
var _max_tasks: int = 2048


func _init(max_tasks: int = 2048) -> void:
	_max_tasks = max_tasks
	_tasks.resize(max_tasks)
	_free_task_indices.resize(max_tasks)
	for i in range(max_tasks):
		_free_task_indices[i] = (max_tasks - 1) - i


## Registers a list of functions to be callable remotely under a scope.
## [br]
## [b]scope_name[/b]: A namespace string (e.g., "Player", "Chat").
## [b]remote_functions[/b]: An array of [Callable]s to register.
func register(scope_name: StringName, remote_functions: Array[Callable]) -> void:
	for function_callable in remote_functions:
		var function_name: StringName = function_callable.get_method()
		if function_name == &"<anonymous lambda>":
			push_error("[gRPC] Lambdas não são permitidas.")
			continue

		var function_id: int = str(scope_name, ".", function_name).hash()
		if _lookup.has(function_id):
			push_error("[gRPC] Conflito de ID para %s.%s." % [scope_name, function_name])
			continue

		var argument_types: Array[int] = _extract_argument_types(function_callable.get_object(), function_name)
		_lookup[function_id] = RpcMethodEntry.new(function_callable, argument_types)


## Unregisters functions for a given scope.
## [br]
## [b]p_scope_name[/b]: The namespace string used in registration.
## [b]p_remote_functions[/b]: The functions to unregister.
func unregister(scope_name: StringName, remote_functions: Array[Callable]) -> void:
	for function_callable in remote_functions:
		var function_id: int = str(scope_name, ".", function_callable.get_method()).hash()
		_lookup.erase(function_id)


## [b]Internal:[/b] Processes raw packet data received from the network.
## [br]
## [b]sender_id[/b]: The ID of the peer sending the packet.
## [b]packet_buffer[/b]: The raw byte buffer of the packet.
## [b]channel_id[/b]: The channel ID where the packet was received.
func _process_packet(sender_id: int, packet_buffer: PackedByteArray, channel_id: int) -> void:
	var packet_data: Variant = bytes_to_var(packet_buffer)
	if typeof(packet_data) != TYPE_ARRAY:
		return

	var packet_array: Array = packet_data as Array
	if packet_array.is_empty() or typeof(packet_array[0]) != TYPE_INT:
		return

	var message_type: int = packet_array[0]
	match message_type:
		Type.EXEC:
			_handle_exec(sender_id, packet_array)
		Type.INVOKE:
			_handle_invoke(sender_id, packet_array, channel_id)
		Type.RESULT:
			_handle_result(packet_array)


## [b]Internal:[/b] Handles an incoming EXEC (fire-and-forget) packet.
func _handle_exec(sender_id: int, packet: Array) -> void:
	if packet.size() < 3: return

	var function_id: int = packet[1]
	var arguments: Array = packet[2]

	var method_entry: RpcMethodEntry = _lookup.get(function_id)
	if method_entry == null:
		push_error("[gRPC] Peer %d tentou EXEC em função não registrada." % sender_id)
		return

	if not _validate_arguments(method_entry.argument_types, arguments):
		push_error("[gRPC] Argumentos inválidos para EXEC de Peer %d." % sender_id)
		return

	method_entry.function_callable.callv(arguments)

## [b]Internal:[/b] Handles an incoming INVOKE (request-response) packet.
func _handle_invoke(sender_id: int, packet: Array, channel_id: int) -> void:
	if packet.size() < 4: return

	var function_id: int = packet[1]
	var arguments: Array = packet[2]
	var task_id: int = packet[3]

	var method_entry: RpcMethodEntry = _lookup.get(function_id)
	if method_entry == null or not _validate_arguments(method_entry.argument_types, arguments):
		return

	var result_value: Variant = await method_entry.function_callable.callv(arguments)
	_send(sender_id, [Type.RESULT, result_value, task_id], channel_id)


## [b]Internal:[/b] Handles an incoming RESULT packet (response to an INVOKE).
func _handle_result(packet: Array) -> void:
	if packet.size() < 3: return

	var return_value: Variant = packet[1]
	var task_id: int = packet[2]

	if task_id < 0 or task_id >= _max_tasks:
		return

	var pending_task: RpcTask = _tasks[task_id]
	if pending_task:
		pending_task.done.emit(return_value)


## [b]Virtual:[/b] Sends raw data. Must be implemented by subclasses.
func _send_raw(_peer_id: int, _data: PackedByteArray, _channel_id: int) -> void:
	pass


## [b]Internal:[/b] Serializes and sends a formatted packet.
func _send(peer_id: int, packet_array: Array, channel_id: int) -> void:
	_send_raw(peer_id, var_to_bytes(packet_array), channel_id)


## [b]Internal:[/b] Reserves a task slot from the pool.
func _reserve_task_slot() -> int:
	return _free_task_indices.pop_back() if not _free_task_indices.is_empty() else -1


## [b]Internal:[/b] Releases a task slot back to the pool.
func _release_task_slot(task_id: int) -> void:
	_tasks[task_id] = null
	_free_task_indices.push_back(task_id)


## [b]Internal:[/b] Extracts argument types from a method in an object.
func _extract_argument_types(target_object: Object, function_name: StringName) -> Array[int]:
	var methods: Array[Dictionary] = target_object.get_method_list().filter(
		func(m): return m["name"] == function_name
	)

	if methods.is_empty():
		return []

	var args: Array = methods[0]["args"]
	var types: Array[int] = []
	types.resize(args.size())
	for i in range(args.size()):
		types[i] = args[i]["type"]
	return types


## [b]Internal:[/b] Validates if provided arguments match expected types.
func _validate_arguments(expected_types: Array[int], provided_arguments: Array) -> bool:
	if expected_types.size() != provided_arguments.size():
		return false

	for i in range(expected_types.size()):
		if typeof(provided_arguments[i]) != expected_types[i]:
			return false
	return true
