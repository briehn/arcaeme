extends SceneTree

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const NetworkSession = preload("res://scripts/network/network_coop_session.gd")
const TWO_SLIMES = preload("res://resources/prototype/enemies/two_slimes.tres")
const WARDED_STRIKE = preload("res://resources/prototype/cards/expansion/warded_strike.tres")
const ACTIVE_SEAT := 2
const DECK_SIZE := 5

var _session: NetworkSession
var _combat: Node
var _seat: int
var _size: int
var _viewer: String
var _release: String
var _ready_seen := false
var _finished := false
var _steps: Array[Dictionary] = []
var _probes: Dictionary[int, Array] = {}
var _probe_expected := -1
var _probe_before: Dictionary
var _probe_sequence := 0
var _rejections := 0
var _first_sequence := 0
var _frames := PackedStringArray()
var _previous: Dictionary


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 4:
		_fail("Expected port, party size, seat, and release file.")
		return
	_size = int(args[1])
	_seat = int(args[2])
	_viewer = _name(_seat)
	_release = args[3]
	_plan()
	create_timer(36).timeout.connect(func(): _fail("Readiness test timed out at " + _viewer))
	if change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene")) != OK:
		_fail("Could not open the main menu.")
		return
	await scene_changed
	(current_scene.get_node("%StartNetworkCoopButton") as Button).pressed.emit()
	await scene_changed
	_session = current_scene.get_node("Session")
	_combat = current_scene.get_node("%CombatSlot/Combat")
	_session.changed.connect(_observe)
	_session.command_result.connect(_on_result)
	(current_scene.get_node("%Port") as SpinBox).value = int(args[0])
	if _seat == 1:
		var party: OptionButton = current_scene.get_node("%PartySize")
		party.select(party.get_item_index(_size))
		_session.encounter = _fixture()
	(current_scene.get_node("%HostButton" if _seat == 1 else "%JoinButton") as Button).pressed.emit()
	while not _finished:
		_drive()
		await process_frame


func _plan() -> void:
	_step(ACTIVE_SEAT, Authority.Command.END_TURN)
	_probes[_steps.size()] = ["duplicate Ready", "forged Undo", "play while Ready", "second Ready"]
	_step(ACTIVE_SEAT, Authority.Command.UNDO_READY)
	_probes[_steps.size()] = ["delayed Ready", "delayed card", "invalid target", "missing target"]
	_step(ACTIVE_SEAT, Authority.Command.PLAY_CARD, 1)
	_step(ACTIVE_SEAT, Authority.Command.END_TURN)
	_probes[_steps.size()] = ["delayed Undo in same round"]
	_step(ACTIVE_SEAT, Authority.Command.UNDO_READY)
	_step(ACTIVE_SEAT, Authority.Command.END_TURN)
	_remaining_ready()
	_probes[_steps.size()] = ["Undo for closed round"]
	_step(ACTIVE_SEAT, Authority.Command.END_TURN)
	_step(ACTIVE_SEAT, Authority.Command.UNDO_READY)
	for index in 2:
		_step(ACTIVE_SEAT, Authority.Command.PLAY_CARD, index)
	_step(ACTIVE_SEAT, Authority.Command.END_TURN)
	_remaining_ready()
	for index in 2:
		_step(ACTIVE_SEAT, Authority.Command.PLAY_CARD, index)
	_step(ACTIVE_SEAT, Authority.Command.END_TURN)


func _step(seat: int, kind: Authority.Command, target := -1) -> void:
	_steps.append({"seat": seat, "kind": kind, "target": target})


func _remaining_ready() -> void:
	for seat in range(_size, 0, -1):
		if seat != ACTIVE_SEAT:
			_step(seat, Authority.Command.END_TURN)


func _fixture() -> EncounterData:
	var fixture: EncounterData = TWO_SLIMES.duplicate()
	fixture.player_max_hp = 9
	fixture.enemies = TWO_SLIMES.enemies.duplicate()
	for index in fixture.enemies.size():
		fixture.enemies[index] = fixture.enemies[index].duplicate()
	fixture.enemies[0].burning_per_attack = 1
	fixture.enemies[0].poison_per_attack = 1
	fixture.enemies[1].attack_pattern = PackedInt32Array([0, 5, 5])
	fixture.test_deck.assign([WARDED_STRIKE, WARDED_STRIKE, WARDED_STRIKE, WARDED_STRIKE, WARDED_STRIKE])
	return fixture


func _observe() -> void:
	if _finished:
		return
	if _session.status == NetworkSession.Status.DISCONNECTED:
		_fail(_session.message)
		return
	if not _ready_seen and _session.status in [NetworkSession.Status.HOSTING, NetworkSession.Status.WAITING]:
		if _session.local_player != _viewer or _session.party_size != _size or not _session.snapshot.is_empty():
			_fail("Unexpected lobby assignment or early combat state.")
			return
		_ready_seen = true
		print("SEAT_READY ", _seat)
	if _session.status != NetworkSession.Status.ACTIVE:
		return
	var view := _session.snapshot
	if view.revision < _frames.size():
		return
	if view.revision != _frames.size() or not _verify_snapshot(view):
		_fail("Invalid snapshot at revision %d." % view.revision)
		return
	if view.revision > 0 and not _verify_transition(view, _steps[view.revision - 1]):
		_fail("Invalid transition at revision %d, after %s." % [
			view.revision, str(_steps[view.revision - 1])])
		return
	_frames.append(JSON.stringify({"players": view.players, "enemies": view.enemies, "round": view.round,
		"phase": view.phase, "revision": view.revision, "log": view.log}).sha256_text())
	_previous = view
	if view.revision == _steps.size():
		_report(view)


func _verify_snapshot(view: Dictionary) -> bool:
	if (_session.local_player != _viewer or view.viewer != _viewer or view.players.size() != _size
			or view.enemies.size() != 2 or view.has("seed") or view.has("run_stage")
			or view.phase != CombatState.Phase.PLAYER or "Seed" in "\n".join(view.log)):
		return false
	var active: Dictionary = view.players[_seat - 1]
	var unready_living := 0
	for index in _size:
		var player: Dictionary = view.players[index]
		if (player.id != _name(index + 1) or player.has("hand") or player.has("draw_pile")
				or player.has("discard_pile") or player.has("ready_epoch") or player.has("reward_options")):
			return false
		unready_living += int(player.hp > 0 and not player.ended_turn)
	if (view.can_end_turn != (active.hp > 0 and not active.ended_turn)
			or view.can_undo_ready != (active.hp > 0 and active.ended_turn and unready_living > 0)):
		return false
	for card in view.hand:
		var copy_start := (_seat - 1) * DECK_SIZE
		if (card.copy < copy_start or card.copy >= copy_start + DECK_SIZE or card.id != "warded_strike"
				or card.playable != (view.can_end_turn and active.mana > 0)):
			return false
	return true


func _verify_transition(view: Dictionary, step: Dictionary) -> bool:
	if view.round != _previous.round:
		return _verify_final_ready(view, step)
	var playback: bool = step.kind == Authority.Command.PLAY_CARD
	for index in _size:
		var player: Dictionary = view.players[index]
		var expected: Dictionary = _previous.players[index].duplicate()
		if index + 1 == step.seat:
			if playback:
				expected.mana -= 1
				expected.block += 4
			else:
				expected.ended_turn = step.kind == Authority.Command.END_TURN
		if player != expected:
			return false
	for index in view.enemies.size():
		var expected: Dictionary = _previous.enemies[index].duplicate()
		if playback and index == step.target:
			expected.hp -= 3
		if view.enemies[index] != expected:
			return false
	var actor: bool = _seat == step.seat
	if view.ready_epoch != _previous.ready_epoch + int(actor and not playback):
		return false
	var plays_local: bool = actor and playback
	if (view.hand.size() != _previous.hand.size() - int(plays_local)
			or view.discard_count != _previous.discard_count + int(plays_local)
			or view.draw_count != _previous.draw_count):
		return false
	var previous_copies := _copies(_previous)
	if plays_local:
		previous_copies.pop_front()
	return previous_copies == _copies(view)


func _verify_final_ready(view: Dictionary, step: Dictionary) -> bool:
	if step.kind != Authority.Command.END_TURN or view.round != _previous.round + 1:
		return false
	for index in _size:
		var prior: Dictionary = _previous.players[index]
		if prior.hp > 0 and prior.ended_turn != (index + 1 != step.seat):
			return false
		var next: Dictionary = view.players[index]
		var next_hp: int = [8, 6, 3][view.round - 2] if index + 1 == ACTIVE_SEAT else (5 if view.round == 2 else 0)
		if next.hp != next_hp:
			return false
		if next.hp > 0 and (next.ended_turn or next.mana != CombatState.TURN_MANA or next.block != 0
				or next.poison != 0 or next.burning != (1 if view.round == 2 else 2)):
			return false
	for enemy in view.enemies:
		if enemy.action_index != view.round - 1:
			return false
	if view.ready_epoch != _previous.ready_epoch + int(step.seat == _seat):
		return false
	if view.players[_seat - 1].hp > 0 and (view.hand.size() != DECK_SIZE or view.discard_count != 0):
		return false
	return true


func _drive() -> void:
	if not _session.can_submit() or _probe_expected != -1:
		return
	var view := _session.snapshot
	if view.revision >= _steps.size():
		return
	var step := _steps[view.revision]
	if _seat != step.seat:
		return
	var probes: Array = _probes.get(view.revision, [])
	if _seat == ACTIVE_SEAT and not probes.is_empty():
		_start_probe(view, probes.pop_front())
		return
	var footer := _combat.get_node("%EndTurnButton") as Button
	if step.kind != Authority.Command.PLAY_CARD:
		var expect_undo: bool = step.kind == Authority.Command.UNDO_READY
		if footer.disabled or (("Undo Ready" in footer.text) != expect_undo):
			_fail("Footer cannot submit the expected Ready/Undo Ready action.")
			return
		footer.pressed.emit()
		return
	var card := _combat.get_node("%HandCards").get_child(0) as Button
	var enemy := _combat.get_node("%EnemyTargets").get_child(step.target) as Button
	if card.disabled:
		_fail("The original playable card was not available after undo.")
		return
	card.pressed.emit()
	if enemy.disabled or not _session.can_submit() or _session.snapshot.revision != view.revision:
		_fail("Selecting a card must open enemy targeting without sending a play.")
		return
	enemy.pressed.emit()


func _start_probe(view: Dictionary, name: String) -> void:
	_probe_before = view
	_probe_sequence = _session._next_sequence + 1
	var request := {"actor": view.viewer, "round": view.round, "phase": view.phase,
		"ready_epoch": view.ready_epoch, "kind": int(Authority.Command.END_TURN)}
	match name:
		"duplicate Ready":
			_probe_expected = Authority.Result.DUPLICATE
			_probe_sequence = _first_sequence
			request.ready_epoch = 0
		"forged Undo":
			_probe_expected = Authority.Result.WRONG_PLAYER
			request.actor = _name(1)
			request.kind = int(Authority.Command.UNDO_READY)
		"play while Ready", "invalid target", "missing target", "delayed card":
			_probe_expected = Authority.Result.ILLEGAL_ACTION
			request.kind = int(Authority.Command.PLAY_CARD)
			request.copy = view.hand[0].copy
			if name != "missing target":
				request.target = "invalid" if name == "invalid target" else "slime_2"
			if name == "delayed card":
				_probe_expected = Authority.Result.STALE_TURN
				request.ready_epoch = 0
		"second Ready":
			_probe_expected = Authority.Result.ILLEGAL_ACTION
		"delayed Ready":
			_probe_expected = Authority.Result.STALE_TURN
			request.ready_epoch = 0
		"delayed Undo in same round", "Undo for closed round":
			_probe_expected = Authority.Result.STALE_TURN
			request.kind = int(Authority.Command.UNDO_READY)
			request.ready_epoch = 1 if name == "delayed Undo in same round" else 5
			request.round = 1
	if name != "duplicate Ready":
		_session._next_sequence = _probe_sequence
	request.sequence = _probe_sequence
	if _probe_expected == -1 or _session.rpc_id(NetworkSession.SERVER_ID, &"_request_command", request) != OK:
		_fail("Could not send readiness probe " + name)


func _on_result(sequence: int, result: int) -> void:
	if _probe_expected != -1:
		if sequence != _probe_sequence or result != _probe_expected or _session.snapshot != _probe_before:
			_fail("Rejected command mutated its snapshot or returned %s instead of %s." % [
				Authority.Result.keys()[result], Authority.Result.keys()[_probe_expected]])
			return
		_rejections += 1
		_probe_expected = -1
	elif result != Authority.Result.ACCEPTED:
		_fail("Host rejected legal player input.")
	elif _first_sequence == 0:
		_first_sequence = sequence


func _report(view: Dictionary) -> void:
	var footer := _combat.get_node("%EndTurnButton") as Button
	if (view.round != 4 or view.players[ACTIVE_SEAT - 1].hp != 3
			or (_seat == ACTIVE_SEAT and (_rejections != 10 or not view.can_end_turn or footer.disabled))
			or (_seat != ACTIVE_SEAT and (view.can_end_turn or view.can_undo_ready or not footer.disabled))):
		_fail("Final state did not prove sole-survivor Ready. Round %d, survivor HP %d, %d checked rejections, can end %s, can undo %s, footer disabled %s." % [
			view.round, view.players[ACTIVE_SEAT - 1].hp, _rejections, view.can_end_turn, view.can_undo_ready, footer.disabled])
		return
	_finished = true
	print("RESULT round %d, %d matching revisions, sole survivor HP 3 · %s" % [
		view.round, _frames.size(), "\n".join(_frames).sha256_text()])
	if _seat == ACTIVE_SEAT:
		print("Rejected command probes: ", _rejections)
	while not FileAccess.file_exists(_release):
		await create_timer(0.04).timeout
	quit()


func _copies(view: Dictionary) -> Array:
	return view.hand.map(func(card: Dictionary) -> int: return card.copy)


func _name(seat: int) -> String:
	return "Battle Mage %d" % seat


func _fail(message: String) -> void:
	_finished = true
	push_error("%s: %s" % [_viewer, message])
	quit(1)
