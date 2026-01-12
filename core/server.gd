## Server-side implementation for the Rpc system (ERPC).
##
## This class manages the server host, handles multiple client connections,
## and allows sending RPC calls to specific peers, groups, or broadcasting to all.
##
## [b]Example:[/b]
## [codeblock]
## var server = RpcServer.new()
## server.start("*", 8080, 32)
## server.register("Server", [self.login])
## server.peer_connected.connect(self._on_client_connected)
## [/codeblock]
class_name RpcServer
extends RpcBase

## Emitted when a network error occurs.
signal network_error()
## Emitted when a new peer connects (client).
signal peer_connected(peer_id: int)
## Emitted when a peer disconnects.
signal peer_disconnected(peer_id: int)

## Internal ENet host instance.
var _enet_host: ENetConnection = null
## Dictionary of connected peers mapped by their peer_id.
var _peers: Dictionary[int, ENetPacketPeer] = {}

## The peer_id of the sender for the currently processing packet.
var _current_sender_id: int = -1
## Counter to assign unique IDs to peers.
var _next_peer_id: int = 0


## Starts the server on the specified address and port.
## [br]
## [b]address[/b]: Bind address (e.g., "*", "0.0.0.0", "127.0.0.1").
## [b]port[/b]: Port to listen on.
## [b]max_peers[/b]: Maximum number of connected clients.
## [b]max_channels[/b]: Maximum number of channels.
## Returns [constant OK] on success or an [enum Error] code on failure.
func start(address: String, port: int, max_peers: int, max_channels: int = 0) -> Error:
	_enet_host = ENetConnection.new()

	var error: Error = _enet_host.create_host_bound(address, port, max_peers, max_channels)
	if error != OK:
		_enet_host = null
		return error

	return OK


## Stops the server and disconnects all peers.
func stop() -> void:
	if not _enet_host:
		return

	_enet_host.flush()
	_enet_host.destroy()
	_enet_host = null
	_peers.clear()


## Polls network events. Must be called every frame.
## [br]
## [b]timeout_ms[/b]: Max time in milliseconds to spend processing events (default: 0).
func poll(timeout_ms: int = 0) -> void:
	if not _enet_host:
		return

	var start_time_ms: int = Time.get_ticks_msec()
	_poll_events()

	while (Time.get_ticks_msec() - start_time_ms) < timeout_ms:
		_poll_events()


## Executes a remote function on specified target(s) without waiting for a result.
## [br]
## [b]target[/b]: Who to send the RPC to. Can be:
## - [int]: A specific peer ID.
## - [Array]: A list of peer IDs.
## - [Callable]: A filter function taking a peer ID and returning bool.
## - [code]null[/code] or anything else: Broadcast to ALL connected peers.
## [b]function_path[/b]: The full path of the function.
## [b]arguments_list[/b]: Arguments to pass.
func exec(target: Variant, function_path: StringName, arguments_list: Array = [], channel_id: int = 0) -> void:
	var packet_array: Array = [Type.EXEC, function_path.hash(), arguments_list]
	_distribute(target, packet_array, channel_id)

## Invokes a remote function on a specific peer and awaits the result.
## [br]
## [b]peer_id[/b]: The ID of the target peer.
## [b]function_path[/b]: The full path of the function.
## [b]arguments_list[/b]: Arguments to pass.
## Returns the result from the client execution.
func invoke(peer_id: int, function_path: StringName, arguments_list: Array = [], channel_id: int = 0) -> Variant:
	var task_id: int = _reserve_task_slot()
	if task_id == -1:
		push_error("[SERVER] Falha ao reservar slot de task para Peer %d." % peer_id)
		return null

	var task_instance = RpcTask.new()
	_tasks[task_id] = task_instance

	_send(peer_id, [Type.INVOKE, function_path.hash(), arguments_list, task_id], channel_id)

	var result_value: Variant = await task_instance.done
	_release_task_slot(task_id)

	return result_value


## Disconnects a specific peer.
## [br]
## [b]peer_id[/b]: The ID of the peer to kick.
## Disconnects a specific peer.
## [br]
## [b]peer_id[/b]: The ID of the peer to kick.
func kick(peer_id: int) -> void:
	var peer: ENetPacketPeer = _peers.get(peer_id)
	if peer:
		peer.peer_disconnect()


## Returns the ID of the peer that sent the currently processing packet.
func get_sender_id() -> int:
	return _current_sender_id


## [b]Internal:[/b] ENet implementation for sending raw data.
func _send_raw(peer_id: int, data_buffer: PackedByteArray, channel_id: int) -> void:
	var peer: ENetPacketPeer = _peers.get(peer_id)
	if peer:
		peer.send(channel_id, data_buffer, ENetPacketPeer.FLAG_RELIABLE)


## [b]Internal:[/b] Checks for new network events from the host.
func _poll_events() -> void:
	var event: Array = _enet_host.service()
	var event_type: int = event[0]

	match event_type:
		ENetConnection.EventType.EVENT_CONNECT:
			_on_peer_connect(event[1])
		ENetConnection.EventType.EVENT_DISCONNECT:
			_on_peer_disconnect(event[1])
		ENetConnection.EventType.EVENT_RECEIVE:
			_on_packet_received(event[1], event[2])
		ENetConnection.EventType.EVENT_ERROR:
			network_error.emit()


## [b]Internal:[/b] Callback for new peer connection.
func _on_peer_connect(peer: ENetPacketPeer) -> void:
	var peer_id: int = _next_peer_id
	_next_peer_id += 1

	peer.set_meta(&"peer_id", peer_id)
	_peers[peer_id] = peer
	peer_connected.emit(peer_id)


## [b]Internal:[/b] Callback for peer disconnection.
func _on_peer_disconnect(peer: ENetPacketPeer) -> void:
	var peer_id_raw: Variant = peer.get_meta(&"peer_id")
	if typeof(peer_id_raw) == TYPE_INT:
		var peer_id: int = peer_id_raw as int
		_peers.erase(peer_id)
		peer_disconnected.emit(peer_id)


## [b]Internal:[/b] Callback for packet receipt.
func _on_packet_received(peer: ENetPacketPeer, channel_id: int) -> void:
	var peer_id_raw: Variant = peer.get_meta(&"peer_id")
	if typeof(peer_id_raw) == TYPE_INT:
		_current_sender_id = peer_id_raw as int
		_process_packet(_current_sender_id, peer.get_packet(), channel_id)


## [b]Internal:[/b] Logic to distribute packets to multiple targets.
func _distribute(target: Variant, packet_array: Array, channel_id: int) -> void:
	match typeof(target):
		TYPE_INT:
			_send(target as int, packet_array, channel_id)
		TYPE_ARRAY:
			for peer_id in target:
				_send(peer_id, packet_array, channel_id)
		TYPE_CALLABLE:
			for peer_id in _peers:
				if target.call(peer_id):
					_send(peer_id, packet_array, channel_id)
		_:
			for peer_id in _peers:
				_send(peer_id, packet_array, channel_id)
