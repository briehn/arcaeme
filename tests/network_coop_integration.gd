extends SceneTree

const NetworkSession = preload("res://scripts/network/network_coop_session.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const Authority = preload("res://scripts/network/network_combat_authority.gd")
const DATA = preload("res://resources/prototype/local_coop_encounter.tres")
const MENU := "res://scenes/main.tscn"
const NETWORK := "res://scenes/network_coop.tscn"
const ONE := "Battle Mage 1"
const TWO := "Battle Mage 2"

var _session: NetworkSession
var _host: bool
var _party_size: int
var _seat: int
var _local_id: String
var _release_path: String
var _seat_reported := false
var _scenario: String
var _steps: Array[Array]
var _sent_revision := -1
var _reported := false
var _leaving := false
var _probe_expected := -1
var _verified_wrong_player := false
var _verified_duplicate := false


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 6 or args[0] not in ["host", "client"]:
		_fail("Expected role, scenario, UDP port, party size, seat and release path.")
		return
	_host = args[0] == "host"
	_scenario = args[1]
	_party_size = int(args[3])
	_seat = int(args[4])
	_local_id = _mage(_seat)
	_release_path = args[5]
	_steps = _scenario_steps()
	create_timer(35).timeout.connect(func(): _fail("Timed out in %s (%s)." % [_scenario,
		_session.message if is_instance_valid(_session) else "opening menu"]))
	var main_path: String = ProjectSettings.get_setting("application/run/main_scene")
	if change_scene_to_file(main_path) != OK:
		_fail("Could not open the configured main scene.")
		return
	await scene_changed
	var start_button: Button = current_scene.get_node("%StartNetworkCoopButton")
	start_button.pressed.emit()
	await scene_changed
	if current_scene.scene_file_path != NETWORK:
		_fail("The main menu did not open the network screen.")
		return
	_session = current_scene.get_node("Session")
	var port: SpinBox = current_scene.get_node("%Port")
	port.value = int(args[2])
	if _host:
		var size: OptionButton = current_scene.get_node("%PartySize")
		size.select(size.get_item_index(_party_size))
		if _scenario == "victory" and _party_size == 2 and not _check_invalid_host_setup(int(port.value)):
			_fail("Hosting accepted an invalid size or duplicate player identity.")
			return
	_session.changed.connect(_observe_session)
	_session.command_result.connect(_check_command_result)
	var launch: Button = current_scene.get_node("%HostButton" if _host else "%JoinButton")
	launch.pressed.emit()
	if _host:
		if _session.status != NetworkSession.Status.HOSTING:
			_fail(_session.message)
			return
		print("HOST_READY")


func _check_invalid_host_setup(port: int) -> bool:
	if _session.host(port, 1) != ERR_INVALID_PARAMETER or _session.host(port, 5) != ERR_INVALID_PARAMETER:
		return false
	var original := _session.player_ids[1]
	_session.player_ids[1] = _session.player_ids[0]
	var error := _session.host(port, 2)
	_session.player_ids[1] = original
	return error == ERR_INVALID_PARAMETER


func _observe_session() -> void:
	if _session.status in [NetworkSession.Status.HOSTING, NetworkSession.Status.WAITING]:
		if _scenario in ["join-failure", "late-join"]:
			_fail("An uninvited client acquired a seat.")
			return
		var roster := _session.connected_players
		var roster_label: Label = current_scene.get_node("%PartyRoster")
		var combat_slot: Control = current_scene.get_node("%CombatSlot")
		if not _expected_roster(roster) or _session.party_size != _party_size or _local_id != _session.local_player or \
				"%d/%d connected" % [roster.size(), _party_size] not in roster_label.text or combat_slot.visible or \
				not _session.snapshot.is_empty() or _session.can_submit() or _session.submit_end_turn():
			_fail("The waiting roster, assigned seat or disabled combat controls are incorrect.")
			return
		if not _seat_reported:
			_seat_reported = true
			print("SEAT_READY ", _seat)
	_advance.call_deferred()


func _advance() -> void:
	if _leaving:
		return
	if _session.status == NetworkSession.Status.DISCONNECTED:
		_check_disconnect()
		return
	if _session.status != NetworkSession.Status.ACTIVE or _reported:
		return
	var view := _session.snapshot
	var connection: Label = current_scene.get_node("%ConnectionStatus")
	if not _seat_reported or view.viewer != _local_id or view.players.size() != _party_size or \
			_local_id not in connection.text or view.has("seed") or _session.connected_players.size() != _party_size:
		_fail("Incorrect assigned identity, public state or seed visibility.")
		return
	for index in view.players.size():
		var player: Dictionary = view.players[index]
		if player.id != _mage(index + 1) or player.has("hand") or player.has("draw_pile") or player.has("discard_pile"):
			_fail("Public combat state has an incorrect seat or exposes private cards.")
			return
	var first_copy := (_seat - 1) * DATA.test_deck.size()
	for card in view.hand:
		if card.copy < first_copy or card.copy >= first_copy + DATA.test_deck.size():
			_fail("The snapshot contains a different player's card copy.")
			return
	var revision: int = view.revision
	if not _check_progress(view):
		return
	if not _host and _seat == _party_size and _scenario == "victory" and _probe_commands(view):
		return
	if revision == _steps.size():
		if _scenario in ["host-leaves", "client-leaves"]:
			var leaving_seat := 1 if _scenario == "host-leaves" else _party_size
			if _seat == leaving_seat:
				_leave()
		else:
			_report_outcome(view)
		return
	if revision > _steps.size():
		_fail("An action was processed more than once.")
		return
	var step := _steps[revision]
	if step[0] != _local_id or revision == _sent_revision or not _session.can_submit():
		return
	var button := _action_button(step[1], view)
	if button == null or button.disabled:
		_fail("Expected an available %s for %s at revision %d." % [step[1], _local_id, revision])
		return
	_sent_revision = revision
	button.pressed.emit()
	if not _host and (_session.can_submit() or _session.snapshot.revision != revision):
		_fail("The client changed combat state before host confirmation.")


func _expected_roster(roster: PackedStringArray) -> bool:
	if roster.size() < _seat or roster.size() > _party_size:
		return false
	for index in roster.size():
		if roster[index] != _mage(index + 1):
			return false
	return true


func _check_progress(view: Dictionary) -> bool:
	if view.phase != CombatState.Phase.PLAYER:
		return true
	if _scenario == "defeat":
		var expected_round := 1 if view.revision < _party_size else 2
		var expected_hp := 25 if expected_round == 1 else 12
		var ended_count := 0
		for player in view.players:
			if player.hp != expected_hp:
				_fail("The full enemy attack should hit all players only after the final end-turn.")
				return false
			ended_count += int(player.ended_turn)
		if view.round != expected_round or ended_count != view.revision % _party_size:
			_fail("The shared phase advanced before all living players ended.")
			return false
	if _scenario == "survivor" and view.round >= 3:
		for index in range(1, _party_size):
			if view.players[index].hp != 0 or view.players[index].recovered:
				_fail("A defeated Mage recovered before victory.")
				return false
		if (view.round == 4 and view.players[0].hp != 18) or (_seat > 1 and view.can_end_turn):
			_fail("A defeated player could act or the survivor could not mitigate the next attack.")
			return false
	return true


func _probe_commands(view: Dictionary) -> bool:
	if _probe_expected != -1 or not _session.can_submit():
		return true
	if not _verified_wrong_player:
		_probe_expected = Authority.Result.WRONG_PLAYER
		_session.rpc_id(NetworkSession.SERVER_ID, &"_request_command", {
			"actor": "Battle Mage 1", "round": view.round, "phase": view.phase,
			"sequence": 1, "kind": int(Authority.Command.END_TURN),
		})
		return true
	if view.revision > 0 and not _verified_duplicate:
		_probe_expected = Authority.Result.DUPLICATE
		_session.rpc_id(NetworkSession.SERVER_ID, &"_request_command", {
			"actor": view.viewer, "round": view.round, "phase": view.phase,
			"sequence": 1, "kind": int(Authority.Command.END_TURN),
		})
		return true
	return false


func _check_command_result(_sequence: int, result: int) -> void:
	if _probe_expected != -1:
		if result != _probe_expected:
			_fail("The host did not reject an invalid command as expected.")
			return
		if result == Authority.Result.WRONG_PLAYER:
			_verified_wrong_player = true
			print("Verified wrong-player rejection over ENet.")
		else:
			_verified_duplicate = true
			print("Verified duplicate sequence rejection over ENet.")
		_probe_expected = -1
	elif result != Authority.Result.ACCEPTED:
		_fail("A valid UI action was rejected by the host.")


func _action_button(card_id: String, view: Dictionary) -> Button:
	var combat := current_scene.get_node("Layout/CombatSlot/Combat")
	if card_id == "end":
		return combat.get_node("%EndTurnButton")
	for card in view.hand:
		if card.id == card_id:
			for button: Button in combat.get_node("%HandCards").get_children():
				if button.text.begins_with(card.name + "\n"):
					return button
	return null


func _report_outcome(view: Dictionary) -> void:
	if _reported:
		return
	var expected := _expected_health()
	var expected_phase := CombatState.Phase.DEFEAT if _scenario == "defeat" else CombatState.Phase.VICTORY
	var actual: Array[int] = []
	var health_display := PackedStringArray()
	for index in view.players.size():
		var player: Dictionary = view.players[index]
		actual.append(player.hp)
		health_display.append(str(player.hp))
		if player.recovered != (_scenario == "survivor" and index > 0):
			_fail("Recovery applied to the wrong player or at the wrong time.")
			return
	var combat := current_scene.get_node("Layout/CombatSlot/Combat")
	var label: Label = combat.get_node("%TurnLabel")
	var end_turn: Button = combat.get_node("%EndTurnButton")
	if view.phase != expected_phase or actual != expected or \
			not end_turn.disabled or label.text != ("Party Defeat" if _scenario == "defeat" else "Team Victory"):
		_fail("Unexpected outcome %s for %s." % [actual, _scenario])
		return
	if _scenario == "victory" and _seat == _party_size and not (_verified_wrong_player and _verified_duplicate):
		_fail("The last seat did not complete both live rejection probes.")
		return
	if _scenario == "survivor" and _party_size > 2 and view.round != 4:
		_fail("The encounter did not advance through a turn with only one living Mage.")
		return
	_reported = true
	var public_state := {"players": view.players, "enemy_hp": view.enemy_hp, "phase": view.phase,
		"round": view.round, "revision": view.revision, "log": view.log}
	print("PUBLIC_STATE ", JSON.stringify(public_state).sha256_text())
	print("RESULT %s · round %d · HP %s · enemy %d · %d actions" % [label.text, view.round,
		"/".join(health_display), view.enemy_hp, view.revision])
	# The runner releases the participants only after every process reports the terminal snapshot.
	while not FileAccess.file_exists(_release_path):
		await create_timer(0.05).timeout
	quit()


func _expected_health() -> Array[int]:
	if _scenario == "victory":
		var victory_hp: Array[int] = [25, 17, 19, 17]
		return victory_hp.slice(0, _party_size)
	var health: Array[int] = []
	for index in _party_size:
		health.append(0 if _scenario == "defeat" else (18 if index == 0 else 7))
	return health


func _leave() -> void:
	_leaving = true
	var leave_button: Button = current_scene.get_node("%LeaveButton")
	leave_button.pressed.emit()
	await scene_changed
	if current_scene.scene_file_path != MENU or root.multiplayer.has_multiplayer_peer():
		_fail("Leaving did not return to the menu and release the peer.")
		return
	print("RESULT %s" % _scenario)
	quit()


func _check_disconnect() -> void:
	if _session.submit_end_turn():
		_fail("An action was available while disconnected.")
		return
	if _reported:
		if not FileAccess.file_exists(_release_path):
			_fail("A participant left before everyone received the outcome.")
			return
		quit()
	elif _scenario in ["join-failure", "late-join"] and "Could not connect" in _session.message and \
			_session.snapshot.is_empty() and _session.local_player.is_empty():
		print("RESULT connection failure shown" if _scenario == "join-failure" else "RESULT late join refused")
		quit()
	elif _scenario in ["host-leaves", "client-leaves"] and "disconnected" in _session.message:
		var combat := current_scene.get_node_or_null("Layout/CombatSlot/Combat")
		if not _session.snapshot.is_empty() and not (combat.get_node("%EndTurnButton") as Button).disabled:
			_fail("The remaining window left actions enabled.")
			return
		print("RESULT %s" % _scenario)
		quit()
	else:
		_fail(_session.message)


func _scenario_steps() -> Array[Array]:
	var steps: Array[Array] = []
	match _scenario:
		"victory":
			if _party_size == 4:
				steps.append([_mage(4), "basic_block"])
			if _party_size >= 3:
				steps.append([_mage(3), "battle_preparation"])
			steps.append_array([[TWO, "arcane_reversal"], [ONE, "arcane_guard"], [ONE, "battle_preparation"],
				[TWO, "basic_strike"], [TWO, "basic_block"], [ONE, "shieldstrike"], [ONE, "end"]])
			for seat in range(_party_size, 2, -1):
				steps.append([_mage(seat), "end"])
			steps.append_array([[TWO, "end"], [ONE, "basic_block"], [ONE, "battle_preparation"], [ONE, "arcane_reversal"]])
		"survivor":
			steps.append_array([[TWO, "basic_strike"], [TWO, "end"], [ONE, "arcane_guard"], [ONE, "battle_preparation"],
				[ONE, "shieldstrike"]])
			for seat in range(3, _party_size + 1):
				steps.append([_mage(seat), "end"])
			steps.append([ONE, "end"])
			for seat in range(_party_size, 1, -1):
				steps.append([_mage(seat), "end"])
			steps.append_array([[ONE, "basic_block"], [ONE, "battle_preparation"], [ONE, "arcane_reversal"], [ONE, "end"]])
			if _party_size == 2:
				steps.append([ONE, "shieldstrike"])
			else:
				steps.append_array([[ONE, "arcane_guard"], [ONE, "basic_block"], [ONE, "basic_block"],
					[ONE, "end"], [ONE, "basic_strike"]])
		"defeat":
			for seat in range(1, _party_size + 1):
				steps.append([_mage(seat), "end"])
			for seat in range(_party_size, 0, -1):
				steps.append([_mage(seat), "end"])
		"host-leaves", "client-leaves":
			steps.append([TWO, "basic_strike"])
	return steps


func _mage(seat: int) -> String:
	return "Battle Mage %d" % seat


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
