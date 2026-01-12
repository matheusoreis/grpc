# ERPC (Enhanced RPC)

**ERPC** is a lightweight, asynchronous, and type-safe RPC system for Godot 4, built on top of `ENetConnection`. It allows for remote function calls without relying on `NodePath`, `SceneTree`, or the engine's built-in RPC system (which locks you into the scene tree structure).

> **Why ERPC?**
> Godot's built-in RPC is great, but sometimes you want a dedicated networking layer that doesn't depend on your scene hierarchy. ERPC gives you full control with explicit function registration, scoping, and request-response patterns (awaitable RPCs).

## Features

- **Protocol Agnostic**: Logic is decoupled from `Node` and `SceneTree`.
- **Explicit Registration**: Only expose what you want, securely.
- **Namespaces**: Organize your API with scopes (e.g., `Auth.login`, `World.spawn`).
- **Async/Await**: Support for `invoke` to wait for return values from the remote peer.
- **Fire-and-Forget**: Standard `exec` for immediate messages.
- **Type Validation**: Automatic argument type checking before function execution.

## Installation

1. Copy the `addons/grpc` folder to your project's `addons/` directory. (We recommend renaming it to `addons/erpc` if you prefer).
2. Enable the plugin in **Project Settings > Plugins**.

## Quick Start

### 1. Setting up the Server

The server manages connections and exposes functions to clients.

```gdscript
extends Node

var server: RpcServer

func _ready() -> void:
    server = RpcServer.new()
    
    # Start server on port 8080 (max 32 peers)
    var err = server.start("*", 8080, 32)
    if err != OK:
        printerr("Failed to start server")
        return
        
    # Register functions under the "Chat" scope
    server.register("Chat", [self.broadcast_message])
    
    # Listen for connections
    server.peer_connected.connect(func(id): print("Peer connected: ", id))

func _process(_delta: float) -> void:
    # Important: Poll events every frame
    server.poll()

func broadcast_message(sender_id: int, message: String) -> void:
    # Relay message to all other clients
    server.exec(null, "Chat.receive", [message])
```

### 2. Setting up the Client

The client connects to the server and can invoke functions.

```gdscript
extends Node

var client: RpcClient

func _ready() -> void:
    client = RpcClient.new()
    
    # Connect to localhost
    client.start("127.0.0.1", 8080)
    
    # Register client-side functions
    client.register("Chat", [self.on_message_received])

func _process(_delta: float) -> void:
    client.poll()

# Awaiting a return value from the server (Invoke)
func get_server_time() -> void:
    var time_ms = await client.invoke("Server.get_time", [])
    print("Server time is: ", time_ms)

func on_message_received(msg: String) -> void:
    print("New message: ", msg)
```

## API Reference

### RpcServer

- `start(address, port, max_peers)`: Starts the ENet host.
- `exec(target, function, args)`: Sends a fire-and-forget call. `target` can be valid Peer ID, Array of IDs, or `null` (Broadcast).
- `invoke(peer_id, function, args)`: Calls a function and waits for the result (`await`).
- `kick(peer_id)`: Disconnects a user.

### RpcClient

- `start(address, port)`: Connects to a server.
- `exec(function, args)`: Sends a command to the server.
- `invoke(function, args)`: Sends a command and waits for a return value.

### RpcBase (Shared)

- `register(scope, functions)`: Registers a list of methods (Callables) to be accessible remotely.
- `unregister(scope, functions)`: Removes access to methods.
- `poll()`: Must be called periodically to process network packets.

## License

MIT License.
