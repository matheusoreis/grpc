## Client-side implementation for the Rpc system (ERPC).
##
## This class manages the client connection using ENet and allows
## sending and receiving RPC calls to/from the server.
##
## [b]Example:[/b]
## [codeblock]
## var client = RpcClient.new()
## client.start("127.0.0.1", 8080)
## client.register("Client", [self.print_message])
## client.exec("Server.log", ["Hello from client!"])
## [/codeblock]
class_name RpcClient
extends RpcBase

## Emitted when a network error occurs.
signal network_error()
## Emitted when the client successfully connects to the server.
signal connected()
## Emitted when the client disconnects from the server.
signal disconnected()

## Internal ENet host instance.
var _enet_host: ENetConnection = null
## Internal peer representing the server.
var _server_peer: ENetPacketPeer = null


## Starts the client connection to the specified address and port.
## [br]
## [b]address[/b]: The IP address to connect to (e.g., "127.0.0.1").
## [b]port[/b]: The port number.
## [b]max_channels[/b]: Maximum number of channels (default: 0).
## Returns [constant OK] on success or an [enum Error] code on failure.
func start(address: String, port: int, max_channels: int = 0) -> Error:
	_enet_host = ENetConnection.new()

	var error: Error = _enet_host.create_host(1, max_channels)
	if error != OK:
		_enet_host = null
		return error

	_server_peer = _enet_host.connect_to_host(address, port, max_channels)
	if not self._server_peer:
		self._enet_host.destroy()
		self._enet_host = null
		return ERR_CANT_CONNECT

	return OK


## Stops the client and disconnects from the server.
func stop() -> void:
	if not _enet_host:
		return

	if _server_peer:
		_server_peer.peer_disconnect_later()
		await disconnected

	_enet_host.flush()
	_enet_host.destroy()
	_enet_host = null
	_server_peer = null


## Polls network events. Must be called every frame or typically in [method Node._process].
## [br]
## [b]timeout_ms[/b]: Max time in milliseconds to spend processing events (default: 0).
func poll(timeout_ms: int = 0) -> void:
	if not _enet_host:
		return

	var start_time_ms: int = Time.get_ticks_msec()
	_poll_events()

	while (Time.get_ticks_msec() - start_time_ms) < timeout_ms:
		_poll_events()


## Executes a remote function on the server without waiting for a result (Fire-and-forget).
## [br]
## [b]function_path[/b]: The full path of the function (e.g., "Namespace.function").
## [b]arguments_list[/b]: Arguments to pass to the function.
## [b]channel_id[/b]: The channel to send the packet on.
func exec(function_path: StringName, arguments_list: Array = [], channel_id: int = 0) -> void:
	var packet_array: Array = [Type.EXEC, function_path.hash(), arguments_list]
	_send_raw(0, var_to_bytes(packet_array), channel_id)


## Invokes a remote function on the server and awaits the result.
## [br]
## [b]function_path[/b]: The full path of the function.
## [b]arguments_list[/b]: Arguments to pass to the function.
## [b]channel_id[/b]: The channel to send the packet on.
## Returns the result from the server execution.
func invoke(function_path: StringName, arguments_list: Array = [], channel_id: int = 0) -> Variant:
	var task_id: int = _reserve_task_slot()
	if task_id == -1:
		push_error("[CLIENT] Limite de tasks excedido.")
		return null

	var task_instance = RpcTask.new()
	_tasks[task_id] = task_instance

	var packet_array: Array = [Type.INVOKE, function_path.hash(), arguments_list, task_id]
	_send_raw(0, var_to_bytes(packet_array), channel_id)

	var result_value: Variant = await task_instance.done
	_release_task_slot(task_id)

	return result_value


## [b]Internal:[/b] ENet implementation for sending raw data.
func _send_raw(_peer_id: int, data_buffer: PackedByteArray, channel_id: int) -> void:
	if _server_peer:
		_server_peer.send(channel_id, data_buffer, ENetPacketPeer.FLAG_RELIABLE)


## [b]Internal:[/b] Checks for new network events from the host.
func _poll_events() -> void:
	var event: Array = _enet_host.service()
	var event_type: int = event[0]

	if event_type == ENetConnection.EventType.EVENT_NONE:
		return

	match event_type:
		ENetConnection.EventType.EVENT_CONNECT:
			_on_connected(event[1])
		ENetConnection.EventType.EVENT_DISCONNECT:
			_on_disconnected(event[1])
		ENetConnection.EventType.EVENT_RECEIVE:
			_on_packet_received(event[1], event[2])
		ENetConnection.EventType.EVENT_ERROR:
			network_error.emit()


## [b]Internal:[/b] Callback for successful connection.
func _on_connected(peer: ENetPacketPeer) -> void:
	_server_peer = peer
	connected.emit()


## [b]Internal:[/b] Callback for disconnection.
func _on_disconnected(peer: ENetPacketPeer) -> void:
	if peer == _server_peer:
		_server_peer = null
		disconnected.emit()


## [b]Internal:[/b] Callback for receiving a packet.
func _on_packet_received(peer: ENetPacketPeer, channel_id: int) -> void:
	if peer == _server_peer:
		_process_packet(0, peer.get_packet(), channel_id)
