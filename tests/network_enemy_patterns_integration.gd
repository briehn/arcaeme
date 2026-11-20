extends SceneTree

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const NetworkSession = preload("res://scripts/network/network_coop_session.gd")
const ATTACK_COUNT := 4
const ENEMY_CASES := {
	2: {"name": "Slime", "hp": 28, "pattern": [6, 6, 6, 6, 6]},
	3: {"name": "Goblin", "hp": 35, "pattern": [7, 14, 14, 7]},
	4: {"name": "Treant", "hp": 55, "pattern": [4, 4, 10, 4, 4]},
}

var _session: NetworkSession
var _size: int
var _seat: int
var _actor: String
var _enemy: Dictionary
var _release_path: String
var _seated := false
var _finished := false
var _sent_revision := -1
var _digests := PackedStringArray()


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
	_enemy = ENEMY_CASES[_size]
	_release_path = args[3]
	create_timer(35).timeout.connect(func(): _fail("Timed out waiting for enemy pattern at seat %d." % _seat))
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
			_fail("The host rejected a legal End Turn."))
	if _seat == 1:
		var party: OptionButton = current_scene.get_node("%PartySize")
		var enemies: OptionButton = current_scene.get_node("%EnemyPlaytest")
		if enemies.selected != 0 or enemies.get_item_text(_size - 1) != _enemy.name:
			_fail("Standalone enemy selection should start at the default and offer all three fixtures.")
			return
		party.select(party.get_item_index(_size))
		enemies.select(_size - 1)
		enemies.item_selected.emit(enemies.selected)
	var launch: Button = current_scene.get_node("%HostButton" if _seat == 1 else "%JoinButton")
	launch.pressed.emit()
	while not _finished:
		_act()
		await process_frame


func _observe() -> void:
	if _finished:
		return
	if _session.status == NetworkSession.Status.DISCONNECTED:
		_fail(_session.message)
		return
	if _session.status in [NetworkSession.Status.HOSTING, NetworkSession.Status.WAITING] and not _seated:
		if _session.local_player != _actor or _session.party_size != _size or not _session.snapshot.is_empty():
			_fail("The lobby assigned the wrong seat or entered combat before filling.")
			return
		_seated = true
		print("SEAT_READY ", _seat)
	if _session.status != NetworkSession.Status.ACTIVE:
		return
	var view := _session.snapshot
	if not _seated or view.viewer != _actor or view.players.size() != _size or view.has("run_stage") or view.has("seed"):
		_fail("Expected a standalone encounter with the assigned private hand.")
		return
	if view.revision < _digests.size():
		return
	if view.revision != _digests.size():
		_fail("The peer skipped a host revision.")
		return
	if not _verify_state(view):
		return
	_digests.append(JSON.stringify({"players": view.players, "round": view.round, "phase": view.phase,
		"enemy": view.enemy_name, "hp": view.enemy_hp, "intent": view.enemy_attack,
		"revision": view.revision, "log": view.log}).sha256_text())
	if view.revision == _size * ATTACK_COUNT:
		_report(view)


func _verify_state(view: Dictionary) -> bool:
	var revision: int = view.revision
	@warning_ignore("integer_division")
	var attacks_completed := revision / _size
	var damage := 0
	var pattern: Array = _enemy.pattern
	for index in attacks_completed:
		damage += int(pattern[index])
	var defeated := damage >= 36
	var expected_round := attacks_completed if defeated else attacks_completed + 1
	var previous_ended := revision % _size
	var attack: int = pattern[expected_round - 1]
	var valid: bool = (view.enemy_name == _enemy.name and view.enemy_hp == _enemy.hp
		and view.enemy_attack == attack and view.round == expected_round
		and view.phase == (CombatState.Phase.DEFEAT if defeated else CombatState.Phase.PLAYER))
	for index in _size:
		var player: Dictionary = view.players[index]
		var ended := defeated or index < previous_ended
		valid = (valid and player.id == "Battle Mage %d" % (index + 1)
			and player.hp == maxi(0, 36 - damage) and player.ended_turn == ended
			and player.mana == (0 if player.hp == 0 else 3) and player.block == 0)
	var log_attacks := 0
	for entry in view.log:
		if entry.begins_with(_enemy.name + " attacks for "):
			valid = (valid and log_attacks < ATTACK_COUNT
				and entry == "%s attacks for %d damage." % [_enemy.name, pattern[log_attacks]])
			log_attacks += 1
	var enemy_label: Label = _combat().get_node("%EnemyLabel")
	var hud_valid := (enemy_label.text.begins_with(_enemy.name)
		and (defeated or ("Attack all living players for %d damage each" % attack) in enemy_label.text))
	valid = valid and log_attacks == attacks_completed and hud_valid
	valid = valid and view.hand.size() == (0 if defeated else 5)
	if not valid:
		_fail("Unexpected pattern, HP, turn, or HUD at revision %d: %s" % [revision, view])
	return valid


func _act() -> void:
	if not _session.can_submit():
		return
	var view := _session.snapshot
	if view.revision >= _size * ATTACK_COUNT or view.revision == _sent_revision or view.revision % _size + 1 != _seat:
		return
	_sent_revision = view.revision
	var end: Button = _combat().get_node("%EndTurnButton")
	if end.disabled or not end.is_visible_in_tree():
		_fail("The appropriate seat cannot use End Turn.")
		return
	end.pressed.emit()
	if _seat != 1 and (_session.can_submit() or _session.snapshot.revision != view.revision):
		_fail("A client changed intent or HP before the host accepted its action.")


func _combat() -> Node:
	return current_scene.get_node("%CombatSlot").get_node("Combat")


func _report(view: Dictionary) -> void:
	_finished = true
	print("RESULT %s four attacks · round %d · HP %d per player · %d actions · %s" %
		[_enemy.name, view.round, view.players[0].hp, view.revision, "\n".join(_digests).sha256_text()])
	while not FileAccess.file_exists(_release_path):
		await create_timer(0.04).timeout
	quit()


func _fail(message: String) -> void:
	_finished = true
	push_error(message)
	quit(1)
