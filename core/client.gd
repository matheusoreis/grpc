## Cliente gRPC para comunicação com o servidor.
##
## [b]GRpcClient[/b] gerencia a conexão ENet do lado do cliente e permite realizar chamadas remotas 
## tanto de forma unidirecional ([method exec]) quanto bidirecional ([method invoke]).
##
## [b]Tutorial Rápido:[/b]
## 1. Instancie a classe: [code]var client = GRpcClient.new()[/code]
## 2. Conecte ao servidor: [code]client.start("127.0.0.1", 8080)[/code]
## 3. Registre funções: [code]client.register("MyUI", [self.update_chat])[/code]
## 4. Chame o servidor: [code]client.exec("Server.login", ["user", "pass"])[/code]
class_name GRpcClient
extends GRpcBase

## Emitido quando ocorre um erro crítico de rede no cliente.
signal network_error()
## Emitido quando a conexão com o servidor é estabelecida com sucesso.
signal connected()
## Emitido quando a conexão com o servidor é perdida ou encerrada.
signal disconnected()

## [b]Interno:[/b] O host ENet do cliente.
var _enet_host: ENetConnection = null
## [b]Interno:[/b] A referência ao peer do servidor.
var _server_peer: ENetPacketPeer = null

## Inicia a conexão com o servidor.
## [br][br]
## Retorna [code]OK[/code] se a tentativa de conexão foi iniciada com sucesso.
func start(p_address: String, p_port: int, p_max_channels: int = 0) -> Error:
	self._enet_host = ENetConnection.new()

	var error: Error = self._enet_host.create_host(1, p_max_channels)
	if error != OK:
		self._enet_host = null
		return error

	self._server_peer = self._enet_host.connect_to_host(p_address, p_port, p_max_channels)
	if not self._server_peer:
		self._enet_host.destroy()
		self._enet_host = null
		return ERR_CANT_CONNECT

	return OK

## Encerra a conexão e limpa os recursos.
func stop() -> void:
	if not self._enet_host:
		return

	if self._server_peer:
		self._server_peer.peer_disconnect_later()

	self._enet_host.flush()
	self._enet_host.destroy()
	self._enet_host = null
	self._server_peer = null

## Processa os eventos de rede. Deve ser chamado a cada frame.
func process(p_timeout_ms: int = 0) -> void:
	if not self._enet_host:
		return

	var start_time_ms: int = Time.get_ticks_msec()
	self._poll_events()

	while (Time.get_ticks_msec() - start_time_ms) < p_timeout_ms:
		self._poll_events()

## Executa uma função no servidor sem esperar resposta.
func exec(p_function_path: StringName, p_arguments_list: Array = [], p_channel_id: int = 0) -> void:
	var packet_array: Array = [Type.EXEC, p_function_path.hash(), p_arguments_list]
	self._send_raw(0, var_to_bytes(packet_array), p_channel_id)

## Invoca uma função no servidor e aguarda o resultado ([code]await[/code]).
func invoke(p_function_path: StringName, p_arguments_list: Array = [], p_channel_id: int = 0) -> Variant:
	var task_id: int = self._reserve_task_slot()
	if task_id == -1:
		push_error("[CLIENT] Limite de tasks excedido.")
		return null

	var task_instance: GRpcTask = GRpcTask.new()
	self._tasks[task_id] = task_instance

	var packet_array: Array = [Type.INVOKE, p_function_path.hash(), p_arguments_list, task_id]
	self._send_raw(0, var_to_bytes(packet_array), p_channel_id)

	var result_value: Variant = await task_instance.done
	self._release_task_slot(task_id)

	return result_value

## [b]Interno:[/b] Implementação de envio via ENet.
func _send_raw(_p_peer_id: int, p_data_buffer: PackedByteArray, p_channel_id: int) -> void:
	if self._server_peer:
		self._server_peer.send(p_channel_id, p_data_buffer, ENetPacketPeer.FLAG_RELIABLE)

## [b]Interno:[/b] Verifica novos eventos no host.
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

## [b]Interno:[/b] Callback de conexão.
func _on_connected(p_peer: ENetPacketPeer) -> void:
	self._server_peer = p_peer
	self.connected.emit()

## [b]Interno:[/b] Callback de desconexão.
func _on_disconnected(p_peer: ENetPacketPeer) -> void:
	if p_peer == self._server_peer:
		self._server_peer = null
		self.disconnected.emit()

## [b]Interno:[/b] Callback de recebimento de pacote.
func _on_packet_received(p_peer: ENetPacketPeer, p_channel_id: int) -> void:
	if p_peer == self._server_peer:
		self._process_packet(0, p_peer.get_packet(), p_channel_id)
