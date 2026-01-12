## Static utility class for globally accessing the active Rpc instance.
##
## This class acts as a central access point for the RPC system,
## allowing easy retrieval of the current [RpcClient] or [RpcServer] instance.
class_name Network
extends RefCounted

## The active Rpc instance (Client or Server).
static var rpc: RpcBase = null
