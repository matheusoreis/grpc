## Servidor gRPC para gerenciar conexões de múltiplos clientes.
##
## [b]GRpcServer[/b] gerencia múltiplos peers ENet e permite a execução de funções remotas 
## em clientes específicos, grupos de clientes ou em broadcast.
##
## [b]Tutorial Rápido:[/b]
## 1. Instancie a classe: [code]var server = GRpcServer.new()[/code]
## 2. Inicie o servidor: [code]server.start("*", 8080, 32)[/code]
## 3. Registre funções: [code]server.register("Server", [self.get_time])[/code]
## 4. Envie para todos: [code]server.exec(null, "Chat.broadcast", ["Olá!"])[/code]
class_name GRpcServer
extends GRpcBase

## Emitido quando ocorre um erro crítico de rede no host do servidor.
signal network_error()
## Emitido quando um novo cliente se conecta.
signal peer_connected(peer_id: int)
## Emitido quando um cliente se desconecta.
signal peer_disconnected(peer_id: int)

## [b]Interno:[/b] O host ENet do servidor.
var _enet_host: ENetConnection = null
## [b]Interno:[/b] Dicionário de peers conectados indexados por ID.
var _peers: Dictionary[int, ENetPacketPeer] = {}

## [b]Interno:[/b] ID do peer que enviou o pacote atual.
var _current_sender_id: int = -1
## [b]Interno:[/b] Contador para atribuição de IDs únicos aos peers.
var _next_peer_id: int = 0

## Inicia o servidor em uma porta específica.
func start(p_address: String, p_port: int, p_max_peers: int, p_max_channels: int = 0) -> Error:
	self._enet_host = ENetConnection.new()

	var error: Error = self._enet_host.create_host_bound(p_address, p_port, p_max_peers, p_max_channels)
	if error != OK:
		self._enet_host = null
		return error

	return OK

## Para o servidor e desconecta todos os clientes.
func stop() -> void:
	if not self._enet_host:
		return

	self._enet_host.flush()
	self._enet_host.destroy()
	self._enet_host = null
	self._peers.clear()

## Processa eventos de rede. Deve ser chamado a cada frame.
func poll(p_timeout_ms: int = 0) -> void:
	if not self._enet_host:
		return

	var start_time_ms: int = Time.get_ticks_msec()
	self._poll_events()

	while (Time.get_ticks_msec() - start_time_ms) < p_timeout_ms:
		self._poll_events()

## Executa uma função em um ou mais alvos.
## [br][br]
## [b]p_target[/b] pode ser um [int] (ID único), [Array] (lista de IDs), [Callable] (filtro) ou [code]null[/code] (todos).
func exec(p_target: Variant, p_function_path: StringName, p_arguments_list: Array = [], p_channel_id: int = 0) -> void:
	var packet_array: Array = [Type.EXEC, p_function_path.hash(), p_arguments_list]
	self._distribute(p_target, packet_array, p_channel_id)

## Invoca uma função em um cliente específico e aguarda o resultado ([code]await[/code]).
func invoke(p_peer_id: int, p_function_path: StringName, p_arguments_list: Array = [], p_channel_id: int = 0) -> Variant:
	var task_id: int = self._reserve_task_slot()
	if task_id == -1:
		push_error("[SERVER] Falha ao reservar slot de task para Peer %d." % p_peer_id)
		return null

	var task_instance: GRpcTask = GRpcTask.new()
	self._tasks[task_id] = task_instance

	self._send(p_peer_id, [Type.INVOKE, p_function_path.hash(), p_arguments_list, task_id], p_channel_id)

	var result_value: Variant = await task_instance.done
	self._release_task_slot(task_id)

	return result_value

## Desconecta um cliente pelo seu ID.
func kick(p_peer_id: int) -> void:
	var peer: ENetPacketPeer = self._peers.get(p_peer_id)
	if peer:
		peer.peer_disconnect()

## Retorna o ID do remetente do pacote atual.
func get_sender_id() -> int:
	return self._current_sender_id

## [b]Interno:[/b] Implementação de envio via ENet.
func _send_raw(p_peer_id: int, p_data_buffer: PackedByteArray, p_channel_id: int) -> void:
	var peer: ENetPacketPeer = self._peers.get(p_peer_id)
	if peer:
		peer.send(p_channel_id, p_data_buffer, ENetPacketPeer.FLAG_RELIABLE)

## [b]Interno:[/b] Verifica novos eventos no host.
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

## [b]Interno:[/b] Callback de nova conexão.
func _on_peer_connect(p_peer: ENetPacketPeer) -> void:
	var peer_id: int = self._next_peer_id
	self._next_peer_id += 1

	p_peer.set_meta(&"peer_id", peer_id)
	self._peers[peer_id] = p_peer
	self.peer_connected.emit(peer_id)

## [b]Interno:[/b] Callback de desconexão de peer.
func _on_peer_disconnect(p_peer: ENetPacketPeer) -> void:
	var peer_id_raw: Variant = p_peer.get_meta(&"peer_id")
	if typeof(peer_id_raw) == TYPE_INT:
		var peer_id: int = peer_id_raw as int
		self._peers.erase(peer_id)
		self.peer_disconnected.emit(peer_id)

## [b]Interno:[/b] Callback de recebimento de pacote.
func _on_packet_received(p_peer: ENetPacketPeer, p_channel_id: int) -> void:
	var peer_id_raw: Variant = p_peer.get_meta(&"peer_id")
	if typeof(peer_id_raw) == TYPE_INT:
		self._current_sender_id = peer_id_raw as int
		self._process_packet(self._current_sender_id, p_peer.get_packet(), p_channel_id)

## [b]Interno:[/b] Lógica de distribuição de pacotes para múltiplos alvos.
func _distribute(p_target: Variant, p_packet_array: Array, p_channel_id: int) -> void:
	match typeof(p_target):
		TYPE_INT:
			self._send(p_target as int, p_packet_array, p_channel_id)
		TYPE_ARRAY:
			for peer_id in p_target:
				self._send(peer_id, p_packet_array, p_channel_id)
		TYPE_CALLABLE:
			for peer_id in self._peers:
				if p_target.call(peer_id):
					self._send(peer_id, p_packet_array, p_channel_id)
		_:
			for peer_id in self._peers:
				self._send(peer_id, p_packet_array, p_channel_id)
