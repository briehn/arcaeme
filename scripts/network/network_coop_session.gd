extends Node

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")

signal changed
signal command_result(sequence: int, result: int)

enum Status { IDLE, HOSTING, JOINING, ACTIVE, DISCONNECTED }

const LOOPBACK := "127.0.0.1"
const DEFAULT_PORT := 24604
const SERVER_ID := 1
const JOIN_TIMEOUT_SECONDS := 5.0

@export var encounter: EncounterData
@export var player_ids: Array[StringName] = []

var status := Status.IDLE
var hosting := false
var message := "Choose Host or Join. Both instances must use the same UDP port."
var snapshot: Dictionary = {}

var _api: MultiplayerAPI
var _transport: ENetMultiplayerPeer
var _authority: Authority
var _assignments: Dictionary[int, StringName] = {}
var _join_timer: Timer
var _next_sequence := 0
var _pending_sequence := 0


func _ready() -> void:
	_api = multiplayer
	_api.peer_connected.connect(_on_peer_connected)
	_api.peer_disconnected.connect(_on_peer_disconnected)
	_api.connected_to_server.connect(_on_connected_to_server)
	_api.connection_failed.connect(_on_connection_failed)
	_api.server_disconnected.connect(_on_server_disconnected)
	_join_timer = Timer.new()
	_join_timer.one_shot = true
	_join_timer.timeout.connect(_on_connection_failed)
	add_child(_join_timer)


func _exit_tree() -> void:
	_close_transport()


func host(port: int = DEFAULT_PORT) -> Error:
	return _open(port, true)


func join(port: int = DEFAULT_PORT) -> Error:
	return _open(port, false)


func can_submit() -> bool:
	return status == Status.ACTIVE and _pending_sequence == 0


func submit_card(copy_id: int) -> bool:
	return _submit(Authority.Command.PLAY_CARD, copy_id)


func submit_end_turn() -> bool:
	return _submit(Authority.Command.END_TURN)


func _open(port: int, as_host: bool) -> Error:
	if _transport != null:
		return ERR_ALREADY_IN_USE
	if port < 1024 or port > 65535:
		return ERR_INVALID_PARAMETER
	hosting = as_host
	snapshot = {}
	_authority = null
	_assignments.clear()
	_next_sequence = 0
	_pending_sequence = 0
	if hosting and not _valid_host_setup():
		_disconnect("The host needs an encounter and distinct player IDs for each seat.")
		return ERR_INVALID_PARAMETER
	var peer := ENetMultiplayerPeer.new()
	var error: Error
	if hosting:
		peer.set_bind_ip(LOOPBACK)
		error = peer.create_server(port, player_ids.size() - 1)
	else:
		error = peer.create_client(LOOPBACK, port)
	if error != OK:
		_disconnect("Could not %s on UDP port %d (%s)." % ["host" if hosting else "join", port, error_string(error)])
		return error
	_transport = peer
	if hosting:
		_assignments[SERVER_ID] = player_ids[0]
		status = Status.HOSTING
		message = "Host · %s · Waiting on %s:%d" % [player_ids[0], LOOPBACK, port]
	else:
		status = Status.JOINING
		message = "Connecting to %s:%d…" % [LOOPBACK, port]
		_join_timer.start(JOIN_TIMEOUT_SECONDS)
	_api.multiplayer_peer = _transport
	changed.emit()
	return OK


func _valid_host_setup() -> bool:
	if encounter == null or player_ids.size() < 2:
		return false
	for player_id in player_ids:
		if player_id == &"" or player_ids.count(player_id) != 1:
			return false
	return true


func _on_peer_connected(peer_id: int) -> void:
	if not hosting or _transport == null or _assignments.has(peer_id):
		return
	if status != Status.HOSTING or _assignments.size() >= player_ids.size():
		_transport.disconnect_peer(peer_id)
		return
	_assignments[peer_id] = player_ids[_assignments.size()]
	if _assignments.size() == player_ids.size():
		_transport.refuse_new_connections = true
		_authority = Authority.new(encounter, _assignments)
		_publish(0, 0)


func _on_connected_to_server() -> void:
	if status == Status.JOINING:
		message = "Connected to host · Waiting for the encounter."
		changed.emit()


func _on_connection_failed() -> void:
	if status == Status.JOINING:
		_disconnect("Could not connect to the host on localhost. Check that the other instance is hosting on this port.")


func _on_peer_disconnected(peer_id: int) -> void:
	if hosting and _assignments.has(peer_id) and _transport != null:
		_disconnect("A client disconnected. The encounter has ended.")


func _on_server_disconnected() -> void:
	if not hosting and _transport != null:
		_disconnect("The host disconnected. The encounter has ended.")


func _disconnect(reason: String) -> void:
	_join_timer.stop()
	_close_transport()
	_authority = null
	_assignments.clear()
	_pending_sequence = 0
	status = Status.DISCONNECTED
	message = reason
	changed.emit()


func _close_transport() -> void:
	if _transport == null:
		return
	var peer := _transport
	_transport = null
	_api.multiplayer_peer = null
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
		peer.close()


func _submit(kind: Authority.Command, copy_id: int = -1) -> bool:
	if not can_submit():
		return false
	_next_sequence += 1
	_pending_sequence = _next_sequence
	var request := {"actor": snapshot["viewer"], "round": snapshot["round"], "phase": snapshot["phase"],
		"sequence": _pending_sequence, "kind": int(kind)}
	if kind == Authority.Command.PLAY_CARD:
		request["copy"] = copy_id
	if hosting:
		_handle_command(SERVER_ID, request)
	else:
		var error := rpc_id(SERVER_ID, &"_request_command", request)
		if error != OK:
			_disconnect("Could not send the action to the host. The encounter has ended.")
			return false
		message = _connected_message()
		changed.emit()
	return true


@rpc("any_peer", "call_remote", "reliable")
func _request_command(request: Variant) -> void:
	if hosting and _authority != null:
		_handle_command(_api.get_remote_sender_id(), request)


func _handle_command(peer_id: int, request: Variant) -> void:
	var result := _authority.submit(peer_id, request)
	if result == Authority.Result.UNKNOWN_PEER:
		return
	var sequence := 0
	if request is Dictionary and request.get("sequence") is int:
		sequence = request["sequence"]
	if result == Authority.Result.ACCEPTED:
		_publish(peer_id, sequence)
	else:
		_deliver(peer_id, sequence, result)


func _publish(command_peer: int, sequence: int) -> void:
	for peer_id in _assignments:
		_deliver(peer_id, sequence if peer_id == command_peer else 0, Authority.Result.ACCEPTED)


func _deliver(peer_id: int, sequence: int, result: int) -> void:
	var view := _authority.snapshot_for(peer_id)
	if peer_id == SERVER_ID:
		_apply_snapshot(view, sequence, result)
	else:
		_receive_snapshot.rpc_id(peer_id, view, sequence, result)


@rpc("authority", "call_remote", "reliable")
func _receive_snapshot(view: Dictionary, sequence: int, result: int) -> void:
	if not hosting and _transport != null and _api.get_remote_sender_id() == SERVER_ID:
		_apply_snapshot(view, sequence, result)


func _apply_snapshot(view: Dictionary, sequence: int, result: int) -> void:
	if not snapshot.is_empty() and view["revision"] < snapshot["revision"]:
		return
	snapshot = view
	_join_timer.stop()
	status = Status.ACTIVE
	if sequence == _pending_sequence:
		_pending_sequence = 0
	message = _connected_message()
	if result != Authority.Result.ACCEPTED:
		message += " · Action rejected (%s)" % Authority.Result.keys()[result].to_lower().replace("_", " ")
	if sequence != 0:
		command_result.emit(sequence, result)
	changed.emit()


func _connected_message() -> String:
	var pending := " · Waiting for host confirmation" if _pending_sequence > 0 else ""
	return "%s · %s · Connected%s" % ["Host" if hosting else "Client", snapshot["viewer"], pending]
