extends RefCounted
class_name GRpcBase


class GRpcMethodEntry:
	var function_callable: Callable
	var argument_types: Array[int]

	func _init(function_callable: Callable, argument_types: Array[int]) -> void:
		self.function_callable = function_callable
		self.argument_types = argument_types


enum Type {
	EXEC,
	INVOKE,
	RESULT,
}


var _lookup: Dictionary[int, GRpcMethodEntry] = {}
var _tasks: Array[GRpcTask] = []

var _max_tasks: int = 2048


func _init(max_tasks: int = 2048) -> void:
	self._tasks.resize(max_tasks)


func register(scope_name: StringName, remote_functions: Array[Callable]) -> void:
	for function_callable: Callable in remote_functions:
		var function_name: StringName = function_callable.get_method()
		if function_name == &"<anonymous lambda>":
			push_error("[gRPC] Lambdas não são permitidas.")
			return

		var function_id: int = str(scope_name, ".", function_name).hash()
		if self._lookup.has(function_id):
			push_error("[gRPC] Conflito de ID para %s.%s." % [scope_name, function_name])
			return

		var argument_types: Array[int] = self._extract_argument_types(function_callable.get_object(), function_name)
		var method_entry: GRpcMethodEntry = GRpcMethodEntry.new(function_callable, argument_types)

		self._lookup[function_id] = method_entry


func unregister(scope_name: StringName, remote_functions: Array[Callable]) -> void:
	for function_callable: Callable in remote_functions:
		var function_id: int = str(scope_name, ".", function_callable.get_method()).hash()
		self._lookup.erase(function_id)


func _process_packet(sender_id: int, packet_buffer: PackedByteArray, channel_id: int) -> void:
	var packet_data: Variant = bytes_to_var(packet_buffer)
	if typeof(packet_data) != TYPE_ARRAY:
		return

	var packet_array: Array = packet_data as Array
	if packet_array.is_empty():
		return

	if typeof(packet_array[0]) != TYPE_INT:
		return

	var message_type: int = packet_array[0]
	match message_type:
		Type.EXEC:
			self._handle_exec(sender_id, packet_array)
		Type.INVOKE:
			self._handle_invoke(sender_id, packet_array, channel_id)
		Type.RESULT:
			self._handle_result(packet_array)


func _handle_exec(sender_id: int, packet: Array) -> void:
	if packet.size() < 3:
		return

	if typeof(packet[1]) != TYPE_INT or typeof(packet[2]) != TYPE_ARRAY:
		return

	var function_id: int = packet[1]
	var arguments: Array = packet[2]

	var method_entry: GRpcMethodEntry = self._lookup.get(function_id)
	if method_entry == null:
		push_error("[gRPC] Peer %d tentou EXEC em função não registrada." % sender_id)
		return

	if not self._validate_arguments(method_entry.argument_types, arguments):
		push_error("[gRPC] Argumentos inválidos para EXEC de Peer %d." % sender_id)
		return

	method_entry.function_callable.callv(arguments)


func _handle_invoke(sender_id: int, packet: Array, channel_id: int) -> void:
	if packet.size() < 4:
		return

	if typeof(packet[1]) != TYPE_INT or typeof(packet[2]) != TYPE_ARRAY or typeof(packet[3]) != TYPE_INT:
		return

	var function_id: int = packet[1]
	var arguments: Array = packet[2]
	var task_id: int = packet[3]
	var method_entry: GRpcMethodEntry = self._lookup.get(function_id)

	if method_entry == null:
		return

	if not self._validate_arguments(method_entry.argument_types, arguments):
		return

	var result_value: Variant = await method_entry.function_callable.callv(arguments)

	self._send(sender_id, [Type.RESULT, result_value, task_id], channel_id)


func _handle_result(packet: Array) -> void:
	if packet.size() < 3:
		return

	if typeof(packet[2]) != TYPE_INT:
		return

	var return_value: Variant = packet[1]

	var task_id: int = packet[2]
	if task_id < 0 or task_id >= self._max_tasks:
		return

	var pending_task: GRpcTask = self._tasks[task_id]
	if not pending_task:
		return

	pending_task.done.emit(return_value)


func _send_raw(_peer_id: int, _data: PackedByteArray, _channel_id: int) -> void:
	pass


func _send(peer_id: int, packet_array: Array, channel_id: int) -> void:
	self._send_raw(peer_id, var_to_bytes(packet_array), channel_id)


func _reserve_task_slot() -> int:
	for index: int in range(self._max_tasks):
		if self._tasks[index] == null:
			return index
	return -1


func _extract_argument_types(target_object: Object, function_name: StringName) -> Array[int]:
	var argument_types: Array[int] = []
	var methods_list: Array[Dictionary] = target_object.get_method_list()

	for method_info: Dictionary in methods_list:
		if method_info["name"] != function_name:
			continue

		for argument_info: Dictionary in method_info["args"]:
			argument_types.push_back(argument_info["type"])
		break

	return argument_types


func _validate_arguments(expected_types: Array[int], provided_arguments: Array) -> bool:
	if expected_types.size() != provided_arguments.size():
		return false

	for index: int in range(expected_types.size()):
		if typeof(provided_arguments[index]) != expected_types[index]:
			return false

	return true
