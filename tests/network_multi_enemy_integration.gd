extends SceneTree

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const NetworkSession = preload("res://scripts/network/network_coop_session.gd")
const TWO_SLIMES = preload("res://resources/prototype/enemies/two_slimes.tres")
const GOBLIN_TREANT = preload("res://resources/prototype/enemies/goblin_treant.tres")
const THREE_ENEMIES = preload("res://resources/prototype/enemies/three_enemies.tres")
const RUN = preload("res://resources/prototype/battle_mage_run.tres")

var _session: NetworkSession
var _fixture: EncounterData
var _scenario: String
var _seat: int
var _size: int
var _actor: String
var _release: String
var _ready_seen := false
var _finished := false
var _frames := PackedStringArray()
var _expected_result := Authority.Result.ACCEPTED
var _before: Dictionary = {}
var _sent_target := ""
var _probe_target := ""
var _unknown_checked := false
var _dead_checked := false
var _partial_seen := false
var _reward_seen := false
var _selected_reward := ""
var _carry_hp: Array[int] = []
var _boss_seen := false


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 5:
		_fail("Expected port, party size, seat, release file and scenario.")
		return
	_size = int(args[1])
	_seat = int(args[2])
	_actor = "Battle Mage %d" % _seat
	_release = args[3]
	_scenario = args[4]
	match _scenario:
		"TwoSlimes", "Run": _fixture = TWO_SLIMES
		"GoblinTreant": _fixture = GOBLIN_TREANT
		"ThreeEnemies", "Defeat": _fixture = THREE_ENEMIES
		_:
			_fail("Unknown multi-enemy scenario.")
			return
	create_timer(32).timeout.connect(func(): _fail("Multi-enemy scenario timed out for " + _actor))
	if change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene")) != OK:
		_fail("Could not open the main menu.")
		return
	await scene_changed
	(current_scene.get_node("%StartNetworkCoopButton") as Button).pressed.emit()
	await scene_changed
	_session = current_scene.get_node("Session")
	_session.changed.connect(_observe)
	_session.command_result.connect(_on_result)
	(current_scene.get_node("%Port") as SpinBox).value = int(args[0])
	if _seat == 1:
		var party: OptionButton = current_scene.get_node("%PartySize")
		party.select(party.get_item_index(_size))
		if _scenario == "Run":
			# Test the existing run path without adding a multi-enemy route to the game.
			(current_scene.get_node("%ShortRun") as CheckBox).button_pressed = true
			_session.run_data = RUN.duplicate()
			_session.run_data.opening_encounters = [_fixture]
		else:
			var picker: OptionButton = current_scene.get_node("%EnemyPlaytest")
			for index in picker.item_count:
				if picker.get_item_metadata(index) == _fixture:
					picker.select(index)
					picker.item_selected.emit(index)
					break
			if _session.encounter != _fixture:
				_fail("Could not select the requested fixture in the real lobby.")
				return
	(current_scene.get_node("%HostButton" if _seat == 1 else "%JoinButton") as Button).pressed.emit()
	while not _finished:
		_drive()
		await process_frame


func _observe() -> void:
	if _finished:
		return
	if _session.status == NetworkSession.Status.DISCONNECTED:
		_fail(_session.message)
		return
	if not _ready_seen and _session.status in [NetworkSession.Status.HOSTING, NetworkSession.Status.WAITING]:
		if _session.local_player != _actor or not _session.snapshot.is_empty():
			_fail("Unexpected initial seat assignment or premature combat snapshot.")
			return
		_ready_seen = true
		print("SEAT_READY ", _seat)
	if _session.status != NetworkSession.Status.ACTIVE:
		return
	var view := _session.snapshot
	var revision: int = view.get("run_revision", view.revision)
	if revision < _frames.size():
		return
	if revision != _frames.size() or not _verify_snapshot(view):
		_fail("Missing revision or invalid public/private data at revision %d for %s." % [revision, _actor])
		return
	_frames.append(JSON.stringify({
		"players": view.players, "enemies": view.enemies, "round": view.round, "phase": view.phase,
		"revision": revision, "log": view.log, "stage": view.get("run_stage"), "ready": view.get("reward_ready"),
	}).sha256_text())
	if (view.phase == CombatState.Phase.DEFEAT
			or (view.phase == CombatState.Phase.VICTORY and view.get("run_stage", "") != "reward")):
		_report(view)


func _verify_snapshot(view: Dictionary) -> bool:
	if (view.viewer != _actor or view.players.size() != _size or view.has("seed")
			or view.has("reward_offers_by_player") or "Seed" in "\n".join(view.log)):
		return false
	var living := 0
	var boss: bool = view.get("encounter_id") == 2
	var expected_ids: Array[String] = []
	if boss:
		expected_ids.append(String(RUN.boss_encounter.enemy_id))
	else:
		for enemy in _fixture.enemies:
			expected_ids.append(String(enemy.id))
	if view.enemies.size() != expected_ids.size():
		return false
	for index in view.enemies.size():
		var enemy: Dictionary = view.enemies[index]
		var name_expected := RUN.boss_encounter.enemy_name if boss else _fixture.enemies[index].display_name
		if (enemy.id != expected_ids[index] or enemy.name != name_expected or enemy.alive != (enemy.hp > 0)
				or enemy.hp > enemy.max_hp or enemy.alive == enemy.intent.is_empty()):
			return false
		living += int(enemy.alive)
	if not boss and living > 0 and living < view.enemies.size():
		_partial_seen = true
		if view.phase == CombatState.Phase.VICTORY or view.get("run_stage", "") == "reward":
			return false
	for player in view.players:
		if player.has("hand") or player.has("draw_pile") or player.has("reward_options") or player.has("selected_reward"):
			return false
	var in_run := _scenario == "Run"
	var deck := RUN.starting_deck if in_run else _fixture.test_deck
	for card in view.hand:
		var index: int = card.copy if in_run else card.copy - (_seat - 1) * deck.size()
		if index < 0 or index > deck.size():
			return false
		var expected_id := _selected_reward if in_run and boss and index == deck.size() else ""
		if index < deck.size():
			expected_id = String(deck[index].id)
		if expected_id.is_empty() or card.id != expected_id:
			return false
	if view.get("run_stage", "") == "reward":
		if view.phase != CombatState.Phase.VICTORY or living != 0:
			return false
		if view.reward_submitted == (not view.reward_options.is_empty()):
			return false
		if not _reward_seen:
			_reward_seen = true
			for player in view.players:
				_carry_hp.append(player.hp)
	elif view.has("reward_options"):
		return false
	if boss and not _boss_seen:
		_boss_seen = true
		if (not _reward_seen or view.round != 1 or view.revision != 0
				or view.run_deck_count != deck.size() + int(not _selected_reward.is_empty())):
			return false
		for index in _size:
			var player: Dictionary = view.players[index]
			if (player.hp != _carry_hp[index] or player.block != 0
					or player.poison != 0 or player.burning != 0 or player.recovered):
				return false
	return true


func _drive() -> void:
	if not _session.can_submit():
		return
	var view := _session.snapshot
	if view.get("run_stage", "") == "reward":
		if view.reward_ready == _seat - 1 and not view.reward_submitted:
			if _seat == 1:
				_selected_reward = view.reward_options[0].id
			_session.submit_reward(_selected_reward)
		return
	if not view.can_end_turn:
		return
	# Rotate the first active seat after each round to exercise remote plays.
	for offset in _size:
		var player: Dictionary = view.players[(offset + view.round) % _size]
		if player.hp > 0 and not player.ended_turn:
			if player.id != _actor:
				return
			break
	var live: Array = view.enemies.filter(func(enemy: Dictionary) -> bool: return enemy.alive)
	var dead: Array = view.enemies.filter(func(enemy: Dictionary) -> bool: return not enemy.alive)
	var combat := current_scene.get_node("%CombatSlot/Combat")
	if _scenario != "Defeat":
		for index in view.hand.size():
			var card: Dictionary = view.hand[index]
			if not card.playable or not card.targets_enemy:
				continue
			if _seat == 2 and not _unknown_checked and view.enemies.size() > 1:
				_unknown_checked = true
				_probe(view, card.copy, &"missing")
				return
			if not dead.is_empty() and not _dead_checked:
				_dead_checked = true
				_probe(view, card.copy, StringName(dead[0].id))
				return
			# Let every fixture execute its opening intents before attacking.
			if view.round == 1 and view.enemies.size() > 1:
				break
			var target: Dictionary = live[-1]
			var attack := combat.get_node("%HandCards").get_child(index) as Button
			if attack.disabled:
				_fail("A playable card is unavailable before selecting a target.")
				return
			_before = view
			_sent_target = target.id
			attack.pressed.emit()
			if live.size() > 1:
				var slot: int = view.enemies.find(target)
				var button := combat.get_node("%EnemyTargets").get_child(slot) as Button
				if button.disabled:
					_fail("Living target is unavailable in the combat interface.")
					return
				button.pressed.emit()
			return
	(combat.get_node("%EndTurnButton") as Button).pressed.emit()


func _probe(view: Dictionary, copy_id: int, target: StringName) -> void:
	_before = view
	_probe_target = String(target)
	_expected_result = Authority.Result.ILLEGAL_ACTION
	if not _session.submit_card(copy_id, target):
		_fail("Could not submit the target-validation probe.")


func _on_result(_sequence: int, result: int) -> void:
	if result != _expected_result:
		_fail("Unexpected host result %s for %s." % [Authority.Result.keys()[result], _actor])
		return
	var view := _session.snapshot
	if result == Authority.Result.ILLEGAL_ACTION and view != _before:
		_fail("The rejected target altered the combat snapshot.")
	elif result == Authority.Result.ILLEGAL_ACTION:
		print("PROBE ", "UNKNOWN" if _probe_target == "missing" else "DEAD")
	elif not _sent_target.is_empty():
		for index in view.enemies.size():
			var enemy: Dictionary = view.enemies[index]
			var previous: Dictionary = _before.enemies[index]
			if enemy.id == _sent_target:
				if enemy.hp + enemy.block >= previous.hp + previous.block:
					_fail("The selected target did not absorb the card's damage.")
			elif enemy != previous:
				_fail("A single-target card changed a second enemy.")
	_sent_target = ""
	_before = {}
	_expected_result = Authority.Result.ACCEPTED


func _report(view: Dictionary) -> void:
	var defeat := _scenario == "Defeat"
	var expected := CombatState.Phase.DEFEAT if defeat else CombatState.Phase.VICTORY
	var log_text := "\n".join(view.log)
	if (view.phase != expected or (not defeat and not _partial_seen)
			or (not defeat and _seat == 2 and not _unknown_checked)
			or (_scenario == "Run" and (not _boss_seen or view.run_stage != "victory"))
			or (_scenario == "GoblinTreant" and ("Goblin gained 2 Strength." not in log_text
				or "Treant gained 7 Block." not in log_text))):
		_fail("The match ended without exercising the required outcome or mechanics.")
		return
	_finished = true
	print("RESULT %s %s · round %d · %d public revisions · %s" % [
		_scenario, "Defeat" if defeat else "Victory", view.round, _frames.size(), "\n".join(_frames).sha256_text()])
	while not FileAccess.file_exists(_release):
		await create_timer(0.04).timeout
	quit()


func _fail(message: String) -> void:
	_finished = true
	push_error(message)
	quit(1)
