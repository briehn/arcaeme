extends RefCounted

const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const ViewSnapshot = preload("res://scripts/combat/combat_view_snapshot.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const CoopRunState = preload("res://scripts/run/coop_run_state.gd")

enum Command { PLAY_CARD, END_TURN, REWARD }
enum Result { ACCEPTED, UNKNOWN_PEER, MALFORMED, WRONG_PLAYER, DUPLICATE, STALE_TURN, ILLEGAL_ACTION }

var _encounter: EncounterData
var _state: CombatState
var _assignments: Dictionary[int, StringName]
var _last_sequence: Dictionary[int, int] = {}
var _run: CoopRunState
var _run_revision := 0


func _init(encounter: EncounterData, assignments: Dictionary[int, StringName], run_data: RunData = null) -> void:
	_encounter = encounter
	_assignments = assignments.duplicate()
	var player_ids: Array[StringName] = []
	player_ids.assign(_assignments.values())
	if run_data != null:
		_run = CoopRunState.new(run_data, player_ids)
		_encounter = _run.active_encounter
		_state = _run.active_combat
	else:
		_state = CombatState.new(encounter, encounter.shuffle_seed, player_ids)


func snapshot_for(peer_id: int) -> Dictionary:
	if not _assignments.has(peer_id):
		return {}
	var player_id := _assignments[peer_id]
	var view := ViewSnapshot.build(_state, _encounter, player_id)
	if _run != null:
		# Seat-local IDs keep changes to one player's deck size out of other hand snapshots.
		for card in view["hand"]:
			card["copy"] -= _state.players[player_id].first_copy_id
		view.merge(_run.view_fields(player_id))
		view["run_revision"] = _run_revision
	return view


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
	if _run != null and request["encounter_id"] != _run.encounter_id:
		return Result.STALE_TURN
	if request["kind"] == Command.REWARD:
		if not _run.submit_reward(player_id, StringName(request["reward_id"])):
			return Result.ILLEGAL_ACTION
		_encounter = _run.active_encounter
		_state = _run.active_combat
		_run_revision += 1
		return Result.ACCEPTED
	if request["round"] != _state.round_number or request["phase"] != _state.phase or _state.phase != CombatState.Phase.PLAYER:
		return Result.STALE_TURN
	if not _play_combat_command(player_id, request):
		return Result.ILLEGAL_ACTION
	if _run != null:
		_run_revision += 1
		_run.observe_combat_result()
	return Result.ACCEPTED


func _play_combat_command(player_id: StringName, request: Dictionary) -> bool:
	if request["kind"] == Command.END_TURN:
		return _state.end_turn(player_id)
	var copy_id: int = request["copy"]
	if _run != null:
		copy_id += _state.players[player_id].first_copy_id
	if not _state.players[player_id].hand.has(copy_id):
		return false
	var target := _encounter.enemy_id if _state.card_data(copy_id).targets_enemy() else &""
	return _state.play_card(player_id, copy_id, target)


func _valid_shape(request: Dictionary) -> bool:
	if not request.get("actor") is String or not request.get("sequence") is int or request["sequence"] <= 0:
		return false
	if not request.get("kind") is int:
		return false
	if _run != null and (not request.get("encounter_id") is int or request["encounter_id"] <= 0):
		return false
	if request["kind"] == Command.REWARD:
		return _run != null and request.size() == 5 and request.get("reward_id") is String
	if not request.get("round") is int or request["round"] <= 0 or not request.get("phase") is int:
		return false
	var run_fields := 1 if _run != null else 0
	match request["kind"]:
		Command.PLAY_CARD:
			return request.size() == 6 + run_fields and request.get("copy") is int
		Command.END_TURN:
			return request.size() == 5 + run_fields
	return false
