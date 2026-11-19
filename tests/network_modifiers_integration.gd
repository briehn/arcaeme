extends SceneTree

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const NetworkSession = preload("res://scripts/network/network_coop_session.gd")
const FIXTURE = preload("res://resources/prototype/modifier_playtest/encounter.tres")
const FOCUS := "test_battle_focus"
const TWIN := "test_twin_strike"
const GUARD := "test_double_guard"
const END := "end"

var _session: NetworkSession
var _size: int
var _seat: int
var _actor: String
var _release_path: String
var _seated := false
var _finished := false
var _steps: Array[Array] = []
var _round_two_revision: int
var _sent_revision := -1
var _digest_trace := PackedStringArray()


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 4:
		_fail("Expected UDP port, party size, seat, and release path.")
		return
	_size = int(args[1])
	_seat = int(args[2])
	_actor = "Battle Mage %d" % _seat
	_release_path = args[3]
	_build_steps()
	create_timer(35).timeout.connect(func(): _fail("Timed out waiting for modifier seat %d." % _seat))
	if change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene")) != OK:
		_fail("Could not open the main menu.")
		return
	await scene_changed
	(current_scene.get_node("%StartNetworkCoopButton") as Button).pressed.emit()
	await scene_changed
	_session = current_scene.get_node("Session")
	(current_scene.get_node("%Port") as SpinBox).value = int(args[0])
	_session.changed.connect(_observe)
	_session.command_result.connect(func(_sequence: int, result: int):
		if result != Authority.Result.ACCEPTED:
			_fail("The host rejected a valid modifier encounter action."))
	if _seat == 1:
		var party: OptionButton = current_scene.get_node("%PartySize")
		var playtest: CheckBox = current_scene.get_node("%ModifierPlaytest")
		if playtest.button_pressed or _session.encounter == FIXTURE:
			_fail("Strength and Dexterity must be an opt-in fixture.")
			return
		party.select(party.get_item_index(_size))
		playtest.button_pressed = true
		if _session.encounter != FIXTURE:
			_fail("Opting in did not configure the shared modifier fixture.")
			return
	var launch: Button = current_scene.get_node("%HostButton" if _seat == 1 else "%JoinButton")
	launch.pressed.emit()
	while not _finished:
		_act()
		await process_frame


func _build_steps() -> void:
	_steps = [[1, FOCUS], [1, GUARD], [1, TWIN], [2, FOCUS], [2, "shieldstrike"], [2, "arcane_reversal"]]
	for seat in range(1, _size + 1):
		_steps.append([seat, END])
	_round_two_revision = _steps.size()
	_steps.append_array([[1, FOCUS], [1, "arcane_reversal"], [1, TWIN]])


func _observe() -> void:
	if _finished:
		return
	if _session.status == NetworkSession.Status.DISCONNECTED:
		_fail(_session.message)
		return
	if _session.status in [NetworkSession.Status.HOSTING, NetworkSession.Status.WAITING] and not _seated:
		if _session.local_player != _actor or _session.party_size != _size or not _session.snapshot.is_empty():
			_fail("The lobby assigned the wrong seat or entered combat too soon.")
			return
		_seated = true
		print("SEAT_READY ", _seat)
	if _session.status != NetworkSession.Status.ACTIVE:
		return
	var view := _session.snapshot
	if not _seated or view.viewer != _actor or view.players.size() != _size or view.has("run_stage") or view.has("seed"):
		_fail("Expected a standalone host-authoritative encounter and the assigned player's hand.")
		return
	if view.revision < _digest_trace.size():
		return
	if view.revision != _digest_trace.size():
		_fail("The peer skipped a host modifier revision.")
		return
	if not _verify_state(view) or not _verify_hud(view):
		return
	_digest_trace.append(JSON.stringify({"players": view.players, "phase": view.phase, "round": view.round,
		"enemy_hp": view.enemy_hp, "enemy_attack": view.enemy_attack, "enemy_strength": view.enemy_strength,
		"enemy_dexterity": view.enemy_dexterity, "revision": view.revision, "log": view.log}).sha256_text())
	if view.revision == _steps.size():
		_report(view)


func _verify_state(view: Dictionary) -> bool:
	var revision: int = view.revision
	var round_two := revision >= _round_two_revision
	var finished := revision == _steps.size()
	var expected_enemy_hp: int
	if round_two:
		expected_enemy_hp = [29, 29, 11, 0][revision - _round_two_revision]
	else:
		expected_enemy_hp = [60, 60, 60, 50, 50, 39, 29][mini(revision, 6)]
	var valid: bool = (view.enemy_strength == 2 and view.enemy_dexterity == 0 and view.enemy_attack == 11
		and view.enemy_hp == expected_enemy_hp and view.round == (2 if round_two else 1)
		and view.phase == (CombatState.Phase.VICTORY if finished else CombatState.Phase.PLAYER))
	for index in _size:
		var player: Dictionary = view.players[index]
		var stat := 0
		var block := 0
		var hp := 36
		var ended := not round_two and revision >= 7 + index
		if index == 0:
			stat = 4 if revision > _round_two_revision else (2 if revision > 0 else 0)
			if round_two:
				block = 6 if revision == _round_two_revision + 1 else 0
			elif revision > 0:
				block = 14 if revision >= 2 else 4
		elif index == 1:
			stat = 2 if revision >= 4 else 0
			block = 4 if stat > 0 and not round_two else 0
			hp = 29 if round_two else 36
		elif round_two:
			hp = 25
		valid = (valid and player.id == "Battle Mage %d" % (index + 1) and player.strength == stat
			and player.dexterity == stat and player.block == block and player.hp == hp and player.ended_turn == ended)
	if revision == 0 or revision == _round_two_revision:
		valid = valid and view.hand.size() == 5 and view.can_end_turn
	if not valid:
		_fail("Unexpected modifier, damage, Block, or HP at revision %d: %s" % [revision, view])
	return valid


func _verify_hud(view: Dictionary) -> bool:
	var players: Label = _combat().get_node("%PlayerLabel")
	var enemy: Label = _combat().get_node("%EnemyLabel")
	var rows := players.text.split("\n")
	if (rows.size() != _size or "Strength 2" not in enemy.text
			or (view.phase == CombatState.Phase.PLAYER and "11 damage" not in enemy.text)):
		_fail("The enemy HUD did not show the public Strength and adjusted attack.")
		return false
	for index in _size:
		var player: Dictionary = view.players[index]
		var row: String = rows[index]
		var shows_stats := "Strength %d" % player.strength in row and "Dexterity %d" % player.dexterity in row
		var shows_zero := "Strength" in row or "Dexterity" in row
		if (not row.begins_with(player.id) or (player.strength > 0 and not shows_stats)
				or (player.strength == 0 and shows_zero)):
			_fail("The roster HUD did not match the public modifier snapshot.")
			return false
	return true


func _act() -> void:
	if not _session.can_submit():
		return
	var view := _session.snapshot
	if view.revision >= _steps.size() or view.revision == _sent_revision:
		return
	var step := _steps[view.revision]
	if _seat != step[0]:
		return
	_sent_revision = view.revision
	var button := _action_button(step[1], view)
	if button == null or button.disabled or not button.is_visible_in_tree():
		_fail("No usable %s button at revision %d." % [step[1], view.revision])
		return
	button.pressed.emit()
	if _seat != 1 and (_session.can_submit() or _session.snapshot.revision != view.revision):
		_fail("A client advanced combat before the host confirmed its action.")


func _action_button(card_id: String, view: Dictionary) -> Button:
	if card_id == END:
		return _combat().get_node("%EndTurnButton")
	for card in view.hand:
		if card.id == card_id:
			for child in _combat().get_node("%HandCards").get_children():
				var button := child as Button
				if button.text.begins_with(card.name + "\n"):
					return button
	return null


func _combat() -> Node:
	return current_scene.get_node("%CombatSlot").get_node("Combat")


func _report(view: Dictionary) -> void:
	var turn: Label = _combat().get_node("%TurnLabel")
	var end: Button = _combat().get_node("%EndTurnButton")
	if turn.text != "Team Victory" or not end.disabled:
		_fail("The terminal snapshot did not render locked Team Victory.")
		return
	_finished = true
	var health := PackedStringArray()
	for player in view.players:
		health.append(str(player.hp))
	print("RESULT Modifier victory · round %d · HP %s · %d actions · %s" %
		[view.round, "/".join(health), view.revision, "\n".join(_digest_trace).sha256_text()])
	while not FileAccess.file_exists(_release_path):
		await create_timer(0.04).timeout
	quit()


func _fail(message: String) -> void:
	_finished = true
	push_error(message)
	quit(1)
