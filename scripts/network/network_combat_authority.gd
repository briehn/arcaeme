extends RefCounted

const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const ViewSnapshot = preload("res://scripts/combat/combat_view_snapshot.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const CoopRunState = preload("res://scripts/run/coop_run_state.gd")
const SpellDrawingSettings = preload("res://scripts/combat/spell_drawing_settings.gd")
const StrokePayload = preload("res://scripts/network/rune_stroke_payload.gd")
const BOOSTER = preload("res://resources/prototype/cards/spell_ink_booster.tres")
const RECEIVE_ALLOWANCE_MS := 500

enum Command { PLAY_CARD, END_TURN, REWARD, UNDO_READY, ARCANA, PORTAL, SUBMIT_CAST, CANCEL_CAST }
enum Result { ACCEPTED, UNKNOWN_PEER, MALFORMED, WRONG_PLAYER, DUPLICATE, STALE_TURN, ILLEGAL_ACTION }

var _encounter: EncounterData
var _state: CombatState
var _assignments: Dictionary[int, StringName]
var _last_sequence: Dictionary[int, int] = {}
var _run: CoopRunState
var _run_revision := 0
var _spell_drawing: SpellDrawingSettings
var _casts: Dictionary[int, Dictionary] = {}
var _cast_feedback: Dictionary[int, Dictionary] = {}


func _init(encounter: EncounterData, assignments: Dictionary[int, StringName], run_data: RunData = null,
		offer_seed: Variant = null, spell_drawing: SpellDrawingSettings = null) -> void:
	_encounter = encounter
	_assignments = assignments.duplicate()
	_spell_drawing = spell_drawing
	var player_ids: Array[StringName] = []
	player_ids.assign(_assignments.values())
	if run_data != null:
		if _spell_drawing != null and not run_data.starting_deck.has(BOOSTER):
			run_data = run_data.duplicate()
			run_data.starting_deck = run_data.starting_deck.duplicate()
			run_data.starting_deck.append(BOOSTER)
		_run = CoopRunState.new(run_data, player_ids, offer_seed, _spell_drawing, false, true)
		_encounter = _run.active_encounter
		_state = _run.active_combat
	else:
		if _spell_drawing != null and not encounter.test_deck.has(BOOSTER):
			_encounter = encounter.duplicate()
			_encounter.test_deck = encounter.test_deck.duplicate()
			_encounter.test_deck.append(BOOSTER)
		_state = CombatState.new(_encounter, _encounter.shuffle_seed, player_ids, -1, {}, {}, {}, _spell_drawing, false, true)


func snapshot_for(peer_id: int, now_ms := -1) -> Dictionary:
	if not _assignments.has(peer_id):
		return {}
	var player_id := _assignments[peer_id]
	var view := {"viewer": String(player_id), "revision": 0}
	if _state != null:
		view = ViewSnapshot.build(_state, _encounter, player_id)
	if _spell_drawing != null:
		view["casting_enabled"] = true
		if _state != null:
			view["booster_primed"] = _state.players[player_id].spell_booster_primed
		if _casts.has(peer_id):
			var cast := _casts[peer_id].duplicate()
			var now := Time.get_ticks_msec() if now_ms < 0 else now_ms
			cast["remaining_ms"] = maxi(0, cast.deadline_ms - now)
			cast.erase("deadline_ms")
			view["cast"] = cast
	if _run != null:
		# Seat-local IDs keep changes to one player's deck size out of other hand snapshots.
		if _state != null:
			for card in view["hand"]:
				card["copy"] -= _state.players[player_id].first_copy_id
		view.merge(_run.view_fields(player_id))
		view["run_revision"] = _run_revision
	return view


func submit(peer_id: int, request: Variant, now_ms := -1) -> Result:
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
	if request["kind"] == Command.ARCANA:
		if not _run.submit_arcana(player_id, StringName(request["arcana_id"])):
			return Result.ILLEGAL_ACTION
		_encounter = _run.active_encounter
		_state = _run.active_combat
		_run_revision += 1
		return Result.ACCEPTED
	if request["kind"] == Command.REWARD:
		if not _run.submit_reward(player_id, StringName(request["reward_id"])):
			return Result.ILLEGAL_ACTION
		_encounter = _run.active_encounter
		_state = _run.active_combat
		_run_revision += 1
		return Result.ACCEPTED
	if request["kind"] == Command.PORTAL:
		if not _run.submit_portal(player_id, StringName(request["portal_id"])):
			return Result.ILLEGAL_ACTION
		_encounter = _run.active_encounter
		_state = _run.active_combat
		_run_revision += 1
		return Result.ACCEPTED
	# A different seat's accepted action need not invalidate a current play. A change
	# in this seat's readiness does invalidate commands that preceded that change.
	if (_state == null or request["round"] != _state.round_number or request["phase"] != _state.phase
			or _state.phase != CombatState.Phase.PLAYER
			or request["ready_epoch"] != _state.players[player_id].ready_epoch):
		return Result.STALE_TURN
	var now := Time.get_ticks_msec() if now_ms < 0 else now_ms
	if request["kind"] in [Command.SUBMIT_CAST, Command.CANCEL_CAST]:
		return _finish_cast(peer_id, player_id, request, now)
	if _spell_drawing != null and request["kind"] == Command.PLAY_CARD:
		var copy_id := _owned_copy(player_id, request["copy"])
		if copy_id < 0:
			return Result.ILLEGAL_ACTION
		if _state.requires_rune(copy_id):
			return _begin_cast(peer_id, player_id, request, copy_id, now)
		if not _state.card_data(copy_id).is_spell_booster:
			return Result.ILLEGAL_ACTION
	if not _play_combat_command(player_id, request):
		return Result.ILLEGAL_ACTION
	_observe_combat_action()
	return Result.ACCEPTED


func _observe_combat_action() -> void:
	for peer_id in _casts.keys():
		if not _state.is_spell_cast_valid(_assignments[peer_id]):
			_remove_cast(peer_id, _assignments[peer_id], "invalid")
	if _run != null:
		_run_revision += 1
		_run.observe_combat_result()


func _begin_cast(peer_id: int, player_id: StringName, request: Dictionary, copy_id: int, now: int) -> Result:
	var entropy := Crypto.new().generate_random_bytes(16)
	if entropy.size() != 16:
		return Result.ILLEGAL_ACTION
	var target := StringName(request.get("target", ""))
	var cast := _state.begin_spell_cast(player_id, copy_id, target)
	if cast.is_empty():
		return Result.ILLEGAL_ACTION
	cast["token"] = entropy.hex_encode()
	cast["copy"] = request["copy"]
	cast["target"] = String(target)
	cast["deadline_ms"] = _state.start_spell_cast_clock(player_id, now)
	_casts[peer_id] = cast
	return Result.ACCEPTED


func _finish_cast(peer_id: int, player_id: StringName, request: Dictionary, now: int) -> Result:
	var cast := _casts.get(peer_id, {}) as Dictionary
	if cast.is_empty() or request["token"] != cast.token:
		return Result.ILLEGAL_ACTION
	if now >= cast.deadline_ms + RECEIVE_ALLOWANCE_MS:
		_remove_cast(peer_id, player_id, "expired")
		return Result.ILLEGAL_ACTION
	if request["kind"] == Command.CANCEL_CAST:
		_remove_cast(peer_id, player_id, "canceled")
		return Result.ACCEPTED
	var strokes: Variant = StrokePayload.decode(request["strokes"])
	if strokes == null or not _state.is_spell_cast_valid(player_id):
		_remove_cast(peer_id, player_id, "invalid")
		return Result.MALFORMED if strokes == null else Result.ILLEGAL_ACTION
	_casts.erase(peer_id)
	var resolution := _state.submit_spell_cast(player_id, strokes, now)
	var feedback := {"token": cast.token, "status": "invalid"}
	_cast_feedback[peer_id] = feedback
	match resolution:
		CombatState.CastResult.SUCCESS:
			var action: Dictionary = _state.action_history.back()
			feedback["status"] = "success"
			feedback["quality"] = action[&"spell_quality"]
			feedback["power_percent"] = action[&"spell_power_percent"]
			_observe_combat_action()
			return Result.ACCEPTED
		CombatState.CastResult.MISDRAWN:
			feedback["status"] = "misdrawn"
		CombatState.CastResult.EXPIRED:
			feedback["status"] = "expired"
	return Result.ILLEGAL_ACTION


func _remove_cast(peer_id: int, player_id: StringName, status: String) -> void:
	_cast_feedback[peer_id] = {"token": _casts[peer_id].token, "status": status}
	_casts.erase(peer_id)
	_state.cancel_spell_cast(player_id)


func expire_casts(now: int) -> Array[int]:
	var expired: Array[int] = []
	for peer_id in _casts.keys():
		if now >= _casts[peer_id].deadline_ms + RECEIVE_ALLOWANCE_MS:
			_remove_cast(peer_id, _assignments[peer_id], "expired")
			expired.append(peer_id)
	return expired


func take_cast_feedback(peer_id: int) -> Dictionary:
	var feedback := _cast_feedback.get(peer_id, {}) as Dictionary
	_cast_feedback.erase(peer_id)
	return feedback


func has_pending_cast(peer_id: int) -> bool:
	return _casts.has(peer_id)


func _play_combat_command(player_id: StringName, request: Dictionary) -> bool:
	if request["kind"] == Command.END_TURN:
		return _state.end_turn(player_id)
	if request["kind"] == Command.UNDO_READY:
		return _state.undo_ready(player_id)
	var copy_id := _owned_copy(player_id, request["copy"])
	if copy_id < 0:
		return false
	var target := StringName(request.get("target", ""))
	return _state.play_card(player_id, copy_id, target)


func _owned_copy(player_id: StringName, wire_copy: int) -> int:
	var player := _state.players[player_id]
	var offset := player.first_copy_id if _run != null else 0
	for copy_id in player.hand:
		if copy_id - offset == wire_copy:
			return copy_id
	return -1


func _valid_shape(request: Dictionary) -> bool:
	if not request.get("actor") is String or not request.get("sequence") is int or request["sequence"] <= 0:
		return false
	if not request.get("kind") is int:
		return false
	if request["kind"] == Command.ARCANA:
		return (_run != null and request.size() == 5 and request.get("encounter_id") is int
			and request["encounter_id"] == 0 and request.get("arcana_id") is String)
	if _run != null and (not request.get("encounter_id") is int or request["encounter_id"] <= 0):
		return false
	if request["kind"] == Command.REWARD:
		return _run != null and request.size() == 5 and request.get("reward_id") is String
	if request["kind"] == Command.PORTAL:
		return _run != null and request.size() == 5 and request.get("portal_id") is String
	if not request.get("round") is int or request["round"] <= 0 or not request.get("phase") is int:
		return false
	if not request.get("ready_epoch") is int or request["ready_epoch"] < 0:
		return false
	var run_fields := 1 if _run != null else 0
	match request["kind"]:
		Command.PLAY_CARD:
			var target_fields := 1 if request.has("target") else 0
			return request.size() == 7 + run_fields + target_fields and request.get("copy") is int \
				and (not request.has("target") or (request["target"] is String and request["target"].length() <= 128))
		Command.END_TURN, Command.UNDO_READY:
			return request.size() == 6 + run_fields
		Command.SUBMIT_CAST, Command.CANCEL_CAST:
			var submitting: bool = request["kind"] == Command.SUBMIT_CAST
			return (_spell_drawing != null and request.size() == 7 + run_fields + int(submitting)
				and request.get("token") is String and request["token"].length() == 32
				and (not submitting or (request.get("strokes") is PackedByteArray
					and request["strokes"].size() <= StrokePayload.MAX_BYTES)))
	return false
