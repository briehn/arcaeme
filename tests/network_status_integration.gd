extends SceneTree

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const NetworkSession = preload("res://scripts/network/network_coop_session.gd")
const POISON_CARD := "status_test_poison"
const BURNING_CARD := "status_test_burning"
const END_TURN := "end"

var _session: NetworkSession
var _size: int
var _seat: int
var _actor: String
var _release_path: String
var _seated := false
var _finished := false
var _steps: Array[Array] = []
var _round_two_revision: int
var _round_three_revision: int
var _sent_revision := -1
var _digest_trace := PackedStringArray()


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 4:
		_fail("Expected UDP port, party size, seat and release path.")
		return
	_size = int(args[1])
	_seat = int(args[2])
	_actor = "Battle Mage %d" % _seat
	_release_path = args[3]
	_build_steps()
	create_timer(35).timeout.connect(func(): _fail("Timed out waiting for the status encounter at seat %d." % _seat))
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
			_fail("The host rejected a valid status encounter action."))
	if _seat == 1:
		var party: OptionButton = current_scene.get_node("%PartySize")
		var status_playtest: CheckBox = current_scene.get_node("%StatusPlaytest")
		if status_playtest.button_pressed:
			_fail("The status encounter should be opt-in.")
			return
		party.select(party.get_item_index(_size))
		status_playtest.button_pressed = true
	var launch: Button = current_scene.get_node("%HostButton" if _seat == 1 else "%JoinButton")
	launch.pressed.emit()
	while not _finished:
		_act()
		await process_frame


func _build_steps() -> void:
	_steps = [[1, "basic_block"], [1, "arcane_guard"], [1, POISON_CARD], [1, END_TURN],
		[2, POISON_CARD], [2, BURNING_CARD], [2, END_TURN]]
	for seat in range(3, _size + 1):
		_steps.append([seat, END_TURN])
	_round_two_revision = _steps.size()
	_steps.append_array([[2, END_TURN], [1, "basic_block"], [1, "arcane_guard"], [1, BURNING_CARD]])
	for seat in range(3, _size + 1):
		_steps.append([seat, END_TURN])
	_steps.append([1, END_TURN])
	_round_three_revision = _steps.size()
	for seat in range(1, _size + 1):
		_steps.append([seat, END_TURN])


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
		_fail("The status test should use standalone co-op with its assigned private view.")
		return
	if view.revision < _digest_trace.size():
		return
	if view.revision != _digest_trace.size():
		_fail("Missed or skipped a host status revision.")
		return
	if not _check_hud(view) or not _check_expected_state(view):
		return
	_digest_trace.append(JSON.stringify({"players": view.players, "phase": view.phase, "round": view.round,
		"enemy_hp": view.enemy_hp, "enemy_poison": view.enemy_poison, "enemy_burning": view.enemy_burning,
		"revision": view.revision, "log": view.log}).sha256_text())
	if view.revision == _steps.size():
		_report(view)


func _check_expected_state(view: Dictionary) -> bool:
	var valid := true
	if view.revision == 0:
		var card_ids := PackedStringArray()
		for card in view.hand:
			card_ids.append(card.id)
		valid = view.enemy_name == "Training Golem" and view.enemy_hp == 34 and view.enemy_attack == 9 and \
			POISON_CARD in card_ids and BURNING_CARD in card_ids and \
			_match_status(view, 34, 0, 0, 36, 36, 0, 0)
	elif view.revision == 6:
		valid = view.round == 1 and _match_status(view, 34, 8, 5, 36, 36, 0, 0) and view.players[0].block == 12
	elif view.revision == _round_two_revision:
		valid = view.round == 2 and _match_status(view, 21, 7, 3, 34, 25, 1, 3)
		for player in view.players:
			valid = valid and player.block == 0 and player.mana == 3 and not player.ended_turn
	elif view.revision == _round_two_revision + 1:
		valid = view.round == 2 and view.enemy_hp == 21 and view.enemy_poison == 7 and view.enemy_burning == 3
		for index in _size:
			var player: Dictionary = view.players[index]
			var ended := index == 1
			var expected_hp := 34 if index == 0 else 25
			valid = valid and player.hp == expected_hp and player.burning == 3 and \
				player.poison == 1 and player.ended_turn == ended and player.mana == 3
		if _seat == 2:
			valid = valid and view.hand.size() == 5 and not view.can_end_turn and view.can_undo_ready
	elif view.revision == _round_three_revision:
		valid = view.round == 3 and _match_status(view, 6, 6, 4, 28, 10, 2, 5)
	elif view.revision == _steps.size():
		valid = view.phase == CombatState.Phase.VICTORY and view.round == 3 and \
			_match_status(view, 0, 5, 4, 23, 5, 2, 3) and view.hand.is_empty()
		var attacks := 0
		for entry in view.log:
			attacks += int(entry.begins_with("Training Golem attacks"))
		valid = valid and attacks == 2
	if not valid:
		_fail("Unexpected status timing, HP or stack counts at revision %d: %s" % [view.revision, view])
	return valid


func _match_status(view: Dictionary, enemy_hp: int, enemy_poison: int, enemy_burning: int,
		host_hp: int, ally_hp: int, poison: int, burning: int) -> bool:
	if view.enemy_hp != enemy_hp or view.enemy_poison != enemy_poison or view.enemy_burning != enemy_burning:
		return false
	for index in _size:
		var player: Dictionary = view.players[index]
		if player.hp != (host_hp if index == 0 else ally_hp) or player.poison != poison or player.burning != burning:
			return false
	return true


func _check_hud(view: Dictionary) -> bool:
	var enemy: Label = _combat().get_node("%EnemyLabel")
	var players: Label = _combat().get_node("%PlayerLabel")
	var enemy_lines := enemy.text.split("\n")
	var lines := players.text.split("\n")
	if lines.size() != _size or not _shows_counters(enemy_lines[0], view.enemy_poison, view.enemy_burning):
		_fail("The enemy status HUD does not match the host snapshot.")
		return false
	if view.phase == CombatState.Phase.PLAYER and (enemy_lines.size() != 2 or
			not enemy_lines[1].begins_with("On surviving targets") or not _shows_counters(enemy_lines[1], 2, 3)):
		_fail("The HUD did not show the per-attack status applications separately from active stacks.")
		return false
	for index in _size:
		var player: Dictionary = view.players[index]
		if not lines[index].begins_with(player.id) or not _shows_counters(lines[index], player.poison, player.burning):
			_fail("A player's status HUD does not match the host snapshot.")
			return false
	return true


func _shows_counters(line: String, poison: int, burning: int) -> bool:
	var counters := line.split("   ·   ")
	var poison_count := 0
	var burning_count := 0
	for counter in counters:
		poison_count += int(counter.begins_with("Poison "))
		burning_count += int(counter.begins_with("Burning "))
	return poison_count == int(poison > 0) and burning_count == int(burning > 0) and \
		(poison == 0 or "Poison %d" % poison in counters) and (burning == 0 or "Burning %d" % burning in counters)


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
		_fail("No usable %s button for revision %d." % [step[1], view.revision])
		return
	button.pressed.emit()
	if _seat != 1 and (_session.can_submit() or _session.snapshot.revision != view.revision):
		_fail("The client advanced the status encounter without host confirmation.")


func _action_button(card_id: String, view: Dictionary) -> Button:
	if card_id == END_TURN:
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
		_fail("The terminal snapshot did not render a locked Team Victory.")
		return
	_finished = true
	var health := PackedStringArray()
	for player in view.players:
		health.append(str(player.hp))
	print("RESULT Poison victory · round %d · HP %s · %d actions · %s" %
		[view.round, "/".join(health), view.revision, "\n".join(_digest_trace).sha256_text()])
	while not FileAccess.file_exists(_release_path):
		await create_timer(0.04).timeout
	quit()


func _fail(message: String) -> void:
	_finished = true
	push_error(message)
	quit(1)
