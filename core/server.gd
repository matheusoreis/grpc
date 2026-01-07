extends GRpcBase
class_name GRpcServer


signal network_error()

signal peer_connected(peer_id: int)
signal peer_disconnected(peer_id: int)


var _enet_host: ENetConnection = null
var _peers: Dictionary[int, ENetPacketPeer] = {}

var _current_sender_id: int = -1
var _next_peer_id: int = 0


func start(address: String, port: int, max_peers: int, max_channels: int = 0) -> Error:
	self._enet_host = ENetConnection.new()

	var error: Error = self._enet_host.create_host_bound(address, port, max_peers, max_channels)
	if error != OK:
		self._enet_host = null
		return error

	return OK


func stop() -> void:
	if not self._enet_host:
		return

	self._enet_host.flush()
	self._enet_host.destroy()
	self._enet_host = null

	self._peers.clear()


func process(timeout_ms: int = 0) -> void:
	if not self._enet_host:
		return

	var start_time_ms: int = Time.get_ticks_msec()

	self._poll_events()

	while (Time.get_ticks_msec() - start_time_ms) < timeout_ms:
		self._poll_events()


func exec(target: Variant, function_path: StringName, arguments_list: Array = [], channel_id: int = 0) -> void:
	var packet_array: Array = [Type.EXEC, function_path.hash(), arguments_list]

	self._distribute(target, packet_array, channel_id)


func invoke(peer_id: int, function_path: StringName, arguments_list: Array = [], channel_id: int = 0) -> Variant:
	var task_id: int = self._reserve_task_slot()
	if task_id == -1:
		push_error("[SERVER] Falha ao reservar slot de task para Peer %d." % peer_id)
		return null

	var task_instance: GRpcTask = GRpcTask.new()
	self._tasks[task_id] = task_instance

	self._send(peer_id, [Type.INVOKE, function_path.hash(), arguments_list, task_id], channel_id)

	var result_value: Variant = await task_instance.done
	self._tasks[task_id] = null

	return result_value


func kick(peer_id: int) -> void:
	var peer: ENetPacketPeer = self._peers.get(peer_id)
	if not peer:
		return

	peer.peer_disconnect()


func get_sender_id() -> int:
	return self._current_sender_id


func _send_raw(peer_id: int, data_buffer: PackedByteArray, channel_id: int) -> void:
	var peer: ENetPacketPeer = self._peers.get(peer_id)
	if not peer:
		return

	peer.send(channel_id, data_buffer, ENetPacketPeer.FLAG_RELIABLE)


func _poll_events() -> void:
	var event: Array = self._enet_host.service()
	var event_type: int = event[0]

	match event_type:
		ENetConnection.EventType.EVENT_CONNECT:
			self._on_peer_connect(event[1])
		ENetConnection.EventType.EVENT_DISCONNECT:
			self._on_peer_disconnect(event[1])
		ENetConnection.EventType.EVENT_RECEIVE:
			self._on_packet_received(event[1], event[2])
		ENetConnection.EventType.EVENT_ERROR:
			self.network_error.emit()


func _on_peer_connect(peer: ENetPacketPeer) -> void:
	var peer_id: int = self._next_peer_id
	self._next_peer_id += 1

	peer.set_meta(&"peer_id", peer_id)
	self._peers[peer_id] = peer

	self.peer_connected.emit(peer_id)


func _on_peer_disconnect(peer: ENetPacketPeer) -> void:
	var peer_id_raw: Variant = peer.get_meta(&"peer_id")

	if typeof(peer_id_raw) != TYPE_INT:
		return

	var peer_id: int = peer_id_raw as int
	self._peers.erase(peer_id)

	self.peer_disconnected.emit(peer_id)


func _on_packet_received(peer: ENetPacketPeer, channel_id: int) -> void:
	var peer_id_raw: Variant = peer.get_meta(&"peer_id")
	if typeof(peer_id_raw) != TYPE_INT:
		return

	self._current_sender_id = peer_id_raw as int

	var packet_buffer: PackedByteArray = peer.get_packet()
	self._process_packet(self._current_sender_id, packet_buffer, channel_id)


func _distribute(target: Variant, packet_array: Array, channel_id: int) -> void:
	if typeof(target) == TYPE_INT:
		self._send(target as int, packet_array, channel_id)
		return

	if typeof(target) == TYPE_ARRAY:
		for peer_id: int in target:
			self._send(peer_id, packet_array, channel_id)
		return

	if typeof(target) == TYPE_CALLABLE:
		for peer_id: int in self._peers.keys():
			if target.call(peer_id):
				self._send(peer_id, packet_array, channel_id)
		return
