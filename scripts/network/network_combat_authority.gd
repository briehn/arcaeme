extends RefCounted

const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const ViewSnapshot = preload("res://scripts/combat/combat_view_snapshot.gd")

enum Command { PLAY_CARD, END_TURN }
enum Result { ACCEPTED, UNKNOWN_PEER, MALFORMED, WRONG_PLAYER, DUPLICATE, STALE_TURN, ILLEGAL_ACTION }

var _encounter: EncounterData
var _state: CombatState
var _assignments: Dictionary[int, StringName]
var _last_sequence: Dictionary[int, int] = {}


func _init(encounter: EncounterData, assignments: Dictionary[int, StringName]) -> void:
	_encounter = encounter
	_assignments = assignments.duplicate()
	var player_ids: Array[StringName] = []
	player_ids.assign(_assignments.values())
	_state = CombatState.new(encounter, encounter.shuffle_seed, player_ids)


func snapshot_for(peer_id: int) -> Dictionary:
	if not _assignments.has(peer_id):
		return {}
	return ViewSnapshot.build(_state, _encounter, _assignments[peer_id])


func submit(peer_id: int, request: Variant) -> Result:
	if not _assignments.has(peer_id):
		return Result.UNKNOWN_PEER
	if not request is Dictionary or not _valid_shape(request):
		return Result.MALFORMED
	var player_id := _assignments[peer_id]
	if request["actor"] != String(player_id):
		return Result.WRONG_PLAYER
	var sequence: int = request["sequence"]
	if sequence <= _last_sequence.get(peer_id, 0):
		return Result.DUPLICATE
	_last_sequence[peer_id] = sequence
	if request["round"] != _state.round_number or request["phase"] != _state.phase or _state.phase != CombatState.Phase.PLAYER:
		return Result.STALE_TURN
	if request["kind"] == Command.END_TURN:
		return Result.ACCEPTED if _state.end_turn(player_id) else Result.ILLEGAL_ACTION
	var copy_id: int = request["copy"]
	if not _state.players[player_id].hand.has(copy_id):
		return Result.ILLEGAL_ACTION
	var target := _encounter.enemy_id if _state.card_data(copy_id).targets_enemy() else &""
	return Result.ACCEPTED if _state.play_card(player_id, copy_id, target) else Result.ILLEGAL_ACTION


func _valid_shape(request: Dictionary) -> bool:
	if not request.get("actor") is String or not request.get("sequence") is int or request["sequence"] <= 0:
		return false
	if not request.get("round") is int or request["round"] <= 0 or not request.get("kind") is int or not request.get("phase") is int:
		return false
	match request["kind"]:
		Command.PLAY_CARD:
			return request.size() == 6 and request.get("copy") is int
		Command.END_TURN:
			return request.size() == 5
	return false
