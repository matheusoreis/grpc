extends GRpcBase
class_name GRpcClient


signal network_error()

signal connected()
signal disconnected()


var _enet_host: ENetConnection = null
var _server_peer: ENetPacketPeer = null


func start(address: String, port: int, max_channels: int = 0) -> Error:
	self._enet_host = ENetConnection.new()

	var error: Error = self._enet_host.create_host(1, max_channels)
	if error != OK:
		self._enet_host = null
		return error

	self._server_peer = self._enet_host.connect_to_host(address, port, max_channels)

	if not self._server_peer:
		self._enet_host.destroy()
		self._enet_host = null
		return ERR_CANT_CONNECT

	return OK


func stop() -> void:
	if not self._enet_host:
		return

	if self._server_peer:
		self._server_peer.peer_disconnect_later()

	self._enet_host.flush()
	self._enet_host.destroy()

	self._enet_host = null
	self._server_peer = null


func process(timeout_ms: int = 0) -> void:
	if not self._enet_host:
		return

	var start_time_ms: int = Time.get_ticks_msec()

	self._poll_events()

	while (Time.get_ticks_msec() - start_time_ms) < timeout_ms:
		self._poll_events()


func exec(function_path: StringName, arguments_list: Array = [], channel_id: int = 0) -> void:
	var packet_array: Array = [Type.EXEC, function_path.hash(), arguments_list]
	self._send_raw(0, var_to_bytes(packet_array), channel_id)


func invoke(function_path: StringName, arguments_list: Array = [], channel_id: int = 0) -> Variant:
	var task_id: int = self._reserve_task_slot()
	if task_id == -1:
		push_error("[CLIENT] Limite de tasks excedido.")
		return null

	var task_instance: GRpcTask = GRpcTask.new()
	self._tasks[task_id] = task_instance

	var packet_array: Array = [Type.INVOKE, function_path.hash(), arguments_list, task_id]
	self._send_raw(0, var_to_bytes(packet_array), channel_id)

	var result_value: Variant = await task_instance.done
	self._tasks[task_id] = null

	return result_value


func _send_raw(_peer_id: int, data_buffer: PackedByteArray, channel_id: int) -> void:
	if not self._server_peer:
		return

	self._server_peer.send(channel_id, data_buffer, ENetPacketPeer.FLAG_RELIABLE)


func _poll_events() -> void:
	var event: Array = self._enet_host.service()
	var event_type: int = event[0]

	if event_type == ENetConnection.EventType.EVENT_NONE:
		return

	match event_type:
		ENetConnection.EventType.EVENT_CONNECT:
			self._on_connected(event[1])
		ENetConnection.EventType.EVENT_DISCONNECT:
			self._on_disconnected(event[1])
		ENetConnection.EventType.EVENT_RECEIVE:
			self._on_packet_received(event[1], event[2])
		ENetConnection.EventType.EVENT_ERROR:
			self.network_error.emit()


func _on_connected(peer: ENetPacketPeer) -> void:
	self._server_peer = peer
	self.connected.emit()


func _on_disconnected(peer: ENetPacketPeer) -> void:
	if peer != self._server_peer:
		return

	self._server_peer = null
	self.disconnected.emit()


func _on_packet_received(peer: ENetPacketPeer, channel_id: int) -> void:
	if not peer or peer != self._server_peer:
		return

	var packet_buffer: PackedByteArray = peer.get_packet()
	self._process_packet(0, packet_buffer, channel_id)
