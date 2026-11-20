extends SceneTree

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const EnemyAction = preload("res://scripts/combat/enemy_action.gd")
const NetworkSession = preload("res://scripts/network/network_coop_session.gd")
const BUFF_GOBLIN = preload("res://resources/prototype/enemies/strengthening_goblin.tres")
const BLOCK_TREANT = preload("res://resources/prototype/enemies/defensive_treant.tres")

var _session: NetworkSession
var _fixture: EncounterData
var _defensive_fixture := false
var _size: int
var _seat: int
var _actor: String
var _release_path: String
var _seated := false
var _finished := false
var _last_sent_revision := -1
var _digests := PackedStringArray()


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 5:
		_fail("Expected UDP port, party size, seat, release path, and Buff or Block fixture.")
		return
	_size = int(args[1])
	_seat = int(args[2])
	_actor = "Battle Mage %d" % _seat
	_release_path = args[3]
	_defensive_fixture = args[4].to_lower() == "block"
	_fixture = BLOCK_TREANT if _defensive_fixture else BUFF_GOBLIN
	create_timer(35).timeout.connect(func(): _fail("Enemy action scenario timed out at seat %d." % _seat))
	if change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene")) != OK:
		_fail("Could not open the current main menu.")
		return
	await scene_changed
	(current_scene.get_node("%StartNetworkCoopButton") as Button).pressed.emit()
	await scene_changed
	_session = current_scene.get_node("Session")
	(current_scene.get_node("%Port") as SpinBox).value = int(args[0])
	_session.changed.connect(_observe)
	_session.command_result.connect(func(_sequence: int, result: int):
		if result != Authority.Result.ACCEPTED:
			_fail("The host rejected a legal local action."))
	if _seat == 1:
		var party: OptionButton = current_scene.get_node("%PartySize")
		var enemies: OptionButton = current_scene.get_node("%EnemyPlaytest")
		var index := 5 if _defensive_fixture else 4
		var fixture_label := _fixture.enemy_name + (" (Block fixture)" if _defensive_fixture else " (Strength fixture)")
		if enemies.selected != 0 or enemies.get_item_text(index) != fixture_label:
			_fail("Enemy action fixtures must be selectable beside the default enemy.")
			return
		party.select(party.get_item_index(_size))
		enemies.select(index)
		enemies.item_selected.emit(index)
		if _session.encounter != _fixture:
			_fail("The real lobby did not select the requested action fixture.")
			return
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
			_fail("Lobby assigned an unexpected seat or exposed combat before filling.")
			return
		_seated = true
		print("SEAT_READY ", _seat)
	if _session.status != NetworkSession.Status.ACTIVE:
		return
	var view := _session.snapshot
	if not _seated or view.viewer != _actor or view.players.size() != _size or view.has("run_stage") or view.has("seed"):
		_fail("A standalone encounter exposed the wrong viewer, party, or private data.")
		return
	if view.revision < _digests.size():
		return
	if view.revision != _digests.size():
		_fail("A peer missed a host action revision.")
		return
	if not _verify_state(view):
		return
	_digests.append(JSON.stringify({"players": view.players, "round": view.round, "phase": view.phase,
		"enemy": view.enemy_name, "hp": view.enemy_hp, "intent": view.enemy_intent, "block": view.enemy_block,
		"strength": view.enemy_strength, "revision": view.revision, "log": view.log}).sha256_text())
	if view.phase in [CombatState.Phase.VICTORY, CombatState.Phase.DEFEAT]:
		_report(view)


func _verify_state(view: Dictionary) -> bool:
	var action_index := 0
	var strength := 0
	var block := 0
	var damage := 0
	var valid: bool = view.enemy_name == _fixture.enemy_name
	for entry in view.log:
		if not entry.begins_with(_fixture.enemy_name + " "):
			continue
		var details: String = entry.trim_prefix(_fixture.enemy_name + " ")
		if details.begins_with("gained ") or details.begins_with("attacks for "):
			var action := _expected_action(action_index + 1, strength)
			match action.kind:
				EnemyAction.Kind.ATTACK:
					valid = valid and details == "attacks for %d damage." % action.amount
				EnemyAction.Kind.BLOCK:
					valid = valid and details == "gained %d Block." % action.amount
					block += action.amount
				EnemyAction.Kind.GAIN_STRENGTH:
					valid = valid and details == "gained %d Strength." % action.amount
					strength += action.amount
			action_index += 1
		elif details.begins_with("blocked "):
			block -= details.get_slice(" ", 1).to_int()
			valid = valid and block >= 0
		elif details.begins_with("lost ") and details.ends_with(" remaining Block at action start."):
			valid = valid and block == details.get_slice(" ", 1).to_int()
			block = 0
		elif details.begins_with("took "):
			damage += details.get_slice(" ", 1).to_int()
	var intent := _expected_action(view.round, strength)
	var defeated: bool = view.phase == CombatState.Phase.DEFEAT
	valid = (valid and view.enemy_intent.kind == intent.kind and view.enemy_intent.amount == intent.amount
		and view.enemy_attack == (intent.amount if intent.kind == EnemyAction.Kind.ATTACK else 0)
		and view.enemy_strength == strength and view.enemy_block == block and view.enemy_hp == _fixture.enemy_max_hp - damage
		and action_index == view.round - 1 + int(defeated))
	if view.phase == CombatState.Phase.PLAYER:
		var enemy: Label = _combat().get_node("%EnemyLabel")
		var hint: String
		match intent.kind:
			EnemyAction.Kind.ATTACK: hint = "Attack all living players for %d damage each" % intent.amount
			EnemyAction.Kind.BLOCK: hint = "Gain %d Block" % intent.amount
			EnemyAction.Kind.GAIN_STRENGTH: hint = "Gain %d Strength" % intent.amount
		valid = (valid and hint in enemy.text and (block == 0 or "Block %d" % block in enemy.text)
			and (strength == 0 or "Strength %d" % strength in enemy.text))
	for card in view.hand:
		var first_copy: int = (_seat - 1) * _fixture.test_deck.size()
		valid = valid and card.copy >= first_copy and card.copy < first_copy + _fixture.test_deck.size()
	for player in view.players:
		valid = valid and not player.has("hand") and not player.has("deck") and not player.has("reward_options")
		if not _defensive_fixture:
			var expected_hp := 36 if view.round <= 2 else (26 if view.round == 3 else 12)
			valid = valid and player.hp == (0 if defeated else expected_hp)
		elif view.round == 3:
			valid = valid and player.hp == 32
	if not valid:
		_fail("Unexpected host action, intent, modifiers, or per-seat state at revision %d: %s" % [view.revision, view])
	return valid


func _expected_action(round_number: int, strength: int) -> Dictionary:
	match (round_number - 1) % 3:
		0:
			return {"kind": EnemyAction.Kind.BLOCK, "amount": 8} if _defensive_fixture else {
				"kind": EnemyAction.Kind.GAIN_STRENGTH, "amount": 3}
		1:
			return {"kind": EnemyAction.Kind.ATTACK, "amount": (4 if _defensive_fixture else 7) + strength}
		_:
			return {"kind": EnemyAction.Kind.ATTACK, "amount": (10 if _defensive_fixture else 11) + strength}


func _act() -> void:
	if not _session.can_submit():
		return
	var view := _session.snapshot
	if view.revision == _last_sent_revision:
		return
	for player in view.players:
		if player.hp > 0 and not player.ended_turn:
			if player.id != _actor:
				return
			break
	if _defensive_fixture:
		if view.round == 2 and _seat == 1 and view.enemy_block == 8:
			for card in view.hand:
				if card.id == "basic_strike" and card.playable:
					_submit(view, _card_button(card.name))
					return
			_fail("The seeded host needs a Basic Strike to leave two Block before expiry.")
			return
		if view.round >= 3:
			for card in view.hand:
				if card.playable and card.attack:
					_submit(view, _card_button(card.name))
					return
			if view.enemy_attack > view.players[_seat - 1].block:
				for card in view.hand:
					if card.playable and card.id in ["basic_block", "arcane_guard", "battle_preparation"]:
						_submit(view, _card_button(card.name))
						return
	_submit(view, _combat().get_node("%EndTurnButton"))


func _submit(view: Dictionary, button: Button) -> void:
	if button == null or button.disabled or not button.is_visible_in_tree():
		_fail("The active seat cannot perform the expected button action.")
		return
	_last_sent_revision = view.revision
	button.pressed.emit()
	if _seat != 1 and (_session.can_submit() or _session.snapshot.revision != view.revision):
		_fail("A client advanced combat before the host confirmed the action.")


func _card_button(card_name: String) -> Button:
	for button in _combat().get_node("%HandCards").get_children():
		if button.text.begins_with(card_name + "\n"):
			return button
	return null


func _combat() -> Node:
	return current_scene.get_node("%CombatSlot").get_node("Combat")


func _report(view: Dictionary) -> void:
	var expected := CombatState.Phase.VICTORY if _defensive_fixture else CombatState.Phase.DEFEAT
	var title: Label = _combat().get_node("%TurnLabel")
	var attacked_block: bool = ("%s blocked 6 damage." % _fixture.enemy_name) in view.log
	var expired_block: bool = ("%s lost 2 remaining Block at action start." % _fixture.enemy_name) in view.log
	if (view.phase != expected or title.text != ("Team Victory" if _defensive_fixture else "Party Defeat")
			or (_defensive_fixture and (view.round < 3 or not attacked_block or not expired_block))
			or (not _defensive_fixture and (view.round != 5 or view.enemy_strength != 6))
			or not (_combat().get_node("%EndTurnButton") as Button).disabled):
		_fail("The run did not verify the expected enemy action sequence and final result.")
		return
	_finished = true
	var hp := PackedStringArray()
	for player in view.players:
		hp.append(str(player.hp))
	print("RESULT %s %s · round %d · HP %s · %d actions · %s" %
		[_fixture.enemy_name, title.text, view.round, "/".join(hp), view.revision, "\n".join(_digests).sha256_text()])
	while not FileAccess.file_exists(_release_path):
		await create_timer(0.04).timeout
	quit()


func _fail(message: String) -> void:
	_finished = true
	push_error(message)
	quit(1)
