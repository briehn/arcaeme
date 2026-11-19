extends SceneTree

const NetworkSession = preload("res://scripts/network/network_coop_session.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const Authority = preload("res://scripts/network/network_combat_authority.gd")
const MENU := "res://scenes/main.tscn"
const NETWORK := "res://scenes/network_coop.tscn"

var _session: NetworkSession
var _host: bool
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
	if args.size() != 3 or args[0] not in ["host", "client"]:
		_fail("Expected role, scenario and UDP port.")
		return
	_host = args[0] == "host"
	_scenario = args[1]
	_steps = _scenario_steps()
	create_timer(14).timeout.connect(func(): _fail("Timed out in %s (%s)." % [_scenario,
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
	_session.changed.connect(func(): _advance.call_deferred())
	_session.command_result.connect(_check_command_result)
	var launch: Button = current_scene.get_node("%HostButton" if _host else "%JoinButton")
	launch.pressed.emit()
	if _host:
		if _session.status != NetworkSession.Status.HOSTING:
			_fail(_session.message)
			return
		print("HOST_READY")


func _advance() -> void:
	if _leaving:
		return
	if _session.status == NetworkSession.Status.DISCONNECTED:
		_check_disconnect()
		return
	if _session.status != NetworkSession.Status.ACTIVE:
		return
	var view := _session.snapshot
	var local_id := "Battle Mage 1" if _host else "Battle Mage 2"
	var connection: Label = current_scene.get_node("%ConnectionStatus")
	if view.viewer != local_id or view.players.size() != 2 or local_id not in connection.text or view.has("seed"):
		_fail("Incorrect assigned identity, public state or seed visibility.")
		return
	for card in view.hand:
		if (card.copy < 17) != _host:
			_fail("The snapshot contains a different player's card copy.")
			return
	var revision: int = view.revision
	if not _host and _scenario == "victory" and _probe_commands(view):
		return
	if revision == _steps.size():
		if _scenario in ["host-leaves", "client-leaves"]:
			if _host == (_scenario == "host-leaves"):
				_leave()
		else:
			_report_outcome(view)
		return
	if revision > _steps.size():
		_fail("An action was processed more than once.")
		return
	var step := _steps[revision]
	if step[0] != local_id or revision == _sent_revision or not _session.can_submit():
		return
	var button := _action_button(step[1], view)
	if button == null or button.disabled:
		_fail("Expected an available %s for %s at revision %d." % [step[1], local_id, revision])
		return
	_sent_revision = revision
	button.pressed.emit()
	if not _host and (_session.can_submit() or _session.snapshot.revision != revision):
		_fail("The client changed combat state before host confirmation.")


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
	var expected: Array = {"victory": [25, 17], "survivor": [18, 7], "defeat": [0, 0]}[_scenario]
	var expected_phase := CombatState.Phase.DEFEAT if _scenario == "defeat" else CombatState.Phase.VICTORY
	var actual := [view.players[0].hp, view.players[1].hp]
	var combat := current_scene.get_node("Layout/CombatSlot/Combat")
	var label: Label = combat.get_node("%TurnLabel")
	var end_turn: Button = combat.get_node("%EndTurnButton")
	if view.phase != expected_phase or actual != expected or view.players[1].recovered != (_scenario == "survivor") or \
			not end_turn.disabled or label.text != ("Party Defeat" if _scenario == "defeat" else "Team Victory"):
		_fail("Unexpected outcome %s for %s." % [actual, _scenario])
		return
	_reported = true
	var public_state := {"players": view.players, "enemy_hp": view.enemy_hp, "phase": view.phase,
		"round": view.round, "revision": view.revision, "log": view.log}
	print("PUBLIC_STATE ", JSON.stringify(public_state).sha256_text())
	print("RESULT %s · round %d · HP %d/%d · enemy %d · %d actions" % [label.text, view.round,
		actual[0], actual[1], view.enemy_hp, view.revision])
	# The host stays up until the client has received and verified its terminal snapshot.
	if not _host:
		quit()


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
		quit()
	elif _scenario == "join-failure" and "Could not connect" in _session.message:
		print("RESULT connection failure shown")
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
	const ONE := "Battle Mage 1"
	const TWO := "Battle Mage 2"
	match _scenario:
		"victory":
			return [[TWO, "arcane_reversal"], [ONE, "arcane_guard"], [ONE, "battle_preparation"],
				[TWO, "basic_strike"], [TWO, "basic_block"], [ONE, "shieldstrike"], [ONE, "end"], [TWO, "end"],
				[ONE, "basic_block"], [ONE, "battle_preparation"], [ONE, "arcane_reversal"]]
		"survivor":
			return [[TWO, "basic_strike"], [TWO, "end"], [ONE, "arcane_guard"], [ONE, "battle_preparation"],
				[ONE, "shieldstrike"], [ONE, "end"], [TWO, "end"], [ONE, "basic_block"],
				[ONE, "battle_preparation"], [ONE, "arcane_reversal"], [ONE, "end"], [ONE, "shieldstrike"]]
		"defeat":
			return [[ONE, "end"], [TWO, "end"], [TWO, "end"], [ONE, "end"]]
		"host-leaves", "client-leaves":
			return [[TWO, "basic_strike"]]
	return []


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
