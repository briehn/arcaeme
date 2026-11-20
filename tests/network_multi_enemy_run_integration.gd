extends SceneTree

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EnemyAction = preload("res://scripts/combat/enemy_action.gd")
const NetworkSession = preload("res://scripts/network/network_coop_session.gd")
const RUN = preload("res://resources/prototype/multi_enemy_run.tres")
const NAMES := ["Two Slimes", "Goblin + Treant", "Citadel Warden"]
const IDS := [["slime_1", "slime_2"], ["goblin", "treant"], ["citadel_warden"]]
const REWARDS := ["shieldstrike", "arcane_reversal", "arcane_guard"]

var _session: NetworkSession
var _seat: int
var _size: int
var _actor: String
var _release_path: String
var _seated := false
var _finished := false
var _public_digests := PackedStringArray()
var _started: Array[int] = []
var _rewards_seen: Array[int] = []
var _partial_seen: Array[int] = []
var _carry_hp: Array[int] = []
var _deck := PackedStringArray()
var _opening_hand: Array[int] = []
var _probe_result := -1
var _probe_before: Dictionary
var _probed_target := false
var _probed_old_reward := false
var _sent_before: Dictionary
var _sent_target := ""


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
	for card in RUN.starting_deck:
		_deck.append(String(card.id))
	create_timer(45).timeout.connect(func(): _fail("Short run timed out for " + _actor))
	if change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene")) != OK:
		_fail("Could not open the main menu.")
		return
	await scene_changed
	(current_scene.get_node("%StartNetworkCoopButton") as Button).pressed.emit()
	await scene_changed
	_session = current_scene.get_node("Session")
	(current_scene.get_node("%Port") as SpinBox).value = int(args[0])
	_session.changed.connect(_observe)
	_session.command_result.connect(_on_result)
	if _seat == 1:
		var party: OptionButton = current_scene.get_node("%PartySize")
		party.select(party.get_item_index(_size))
		var route: CheckBox = current_scene.get_node("%MultiEnemyRun")
		if route.button_pressed:
			_fail("The multi-enemy short run must be opt-in.")
			return
		(current_scene.get_node("%ShortRun") as CheckBox).button_pressed = true
		route.button_pressed = true
		if (current_scene.get_node("%HostButton") as Button).text != "Host Multi-Enemy Short Run":
			_fail("The lobby did not identify the selected run.")
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
	if not _seated and _session.status in [NetworkSession.Status.HOSTING, NetworkSession.Status.WAITING]:
		if _session.local_player != _actor or not _session.snapshot.is_empty():
			_fail("Incorrect seat assignment or early combat snapshot.")
			return
		_seated = true
		print("SEAT_READY ", _seat)
	if _session.status != NetworkSession.Status.ACTIVE:
		return
	var view := _session.snapshot
	var revision: int = view.run_revision
	if revision < _public_digests.size():
		return
	if revision != _public_digests.size() or not _verify(view):
		_fail("Unexpected run state at revision %d for %s (%s %d)." %
			[revision, _actor, view.run_stage, view.encounter_id])
		return
	_public_digests.append(JSON.stringify({
		"players": view.players, "enemies": view.enemies, "log": view.log, "round": view.round,
		"phase": view.phase, "stage": view.run_stage, "encounter": view.encounter_id,
		"revision": view.revision, "ready": view.get("reward_ready"),
		"next_encounter": view.get("next_encounter_name"),
	}).sha256_text())
	if view.run_stage in ["victory", "defeat"]:
		_report(view)


func _verify(view: Dictionary) -> bool:
	var encounter: int = view.encounter_id
	if (encounter < 1 or encounter > 3 or view.encounter_count != 3 or view.run_title != RUN.title
			or view.viewer != _actor or view.players.size() != _size or view.has("seed")
			or view.has("reward_offers_by_player") or view.run_deck_count != _deck.size()):
		return false
	var stage_label: Label = current_scene.get_node("%RunStage")
	if ("Encounter %d of 3" % encounter not in stage_label.text
			or (view.run_stage == "boss" and "Boss: Citadel Warden" not in stage_label.text)):
		return false
	var enemies: Array = view.enemies
	if enemies.size() != IDS[encounter - 1].size() or view.enemy_name != NAMES[encounter - 1]:
		return false
	var living := 0
	for index in enemies.size():
		var enemy: Dictionary = enemies[index]
		if enemy.id != IDS[encounter - 1][index] or enemy.alive == enemy.intent.is_empty():
			return false
		living += int(enemy.alive)
	for player in view.players:
		if player.has("hand") or player.has("deck") or player.has("reward_options") or player.has("ready_epoch"):
			return false
	for card in view.hand:
		if card.copy < 0 or card.copy >= _deck.size() or card.id != _deck[card.copy]:
			return false
	if encounter < 3 and living == 1:
		if view.run_stage == "reward" or view.phase == CombatState.Phase.VICTORY:
			return false
		if encounter not in _partial_seen:
			_partial_seen.append(encounter)
	if view.run_stage == "reward":
		return _verify_reward(view, living)
	if view.has("reward_options") or view.has("reward_submitted"):
		return false
	if encounter not in _started:
		return _verify_start(view)
	if encounter == 1 and view.revision in [1, 2]:
		var waiting: bool = view.revision == 1
		if (view.round != 1 or view.players[1].ended_turn != waiting
				or view.players[1].mana != CombatState.TURN_MANA or view.players[1].hp != RUN.player_max_hp):
			return false
		if _seat == 2:
			return _copies(view) == _opening_hand and view.can_undo_ready == waiting and view.can_end_turn != waiting
	return true


func _verify_start(view: Dictionary) -> bool:
	var encounter: int = view.encounter_id
	var stage: String = ["opening", "intermediate", "boss"][encounter - 1]
	if (encounter != _started.size() + 1 or view.revision != 0 or view.round != 1
			or view.run_stage != stage or view.ready_epoch != 0 or view.hand.size() != 5):
		return false
	for index in view.players.size():
		var player: Dictionary = view.players[index]
		var hp := RUN.player_max_hp if encounter == 1 else _carry_hp[index]
		if (player.hp != hp or player.block != 0 or player.poison != 0 or player.burning != 0
				or player.strength != 0 or player.dexterity != 0 or player.ended_turn or player.recovered):
			return false
	for enemy in view.enemies:
		if enemy.action_index != 0 or enemy.hp != enemy.max_hp or enemy.block != 0:
			return false
	if encounter == 1:
		_opening_hand = _copies(view)
	_started.append(encounter)
	return true


func _verify_reward(view: Dictionary, living: int) -> bool:
	var encounter: int = view.encounter_id
	if (encounter > 2 or living != 0 or view.phase != CombatState.Phase.VICTORY
			or view.next_encounter_name != NAMES[encounter] or view.reward_ready >= _size):
		return false
	var progress: Label = current_scene.get_node("%RewardProgress")
	var choices := current_scene.get_node("%RewardChoices")
	if ("%d/%d" % [view.reward_ready, _size] not in progress.text
			or choices.get_child_count() != view.reward_options.size()):
		return false
	if encounter not in _rewards_seen:
		if view.reward_ready != 0:
			return false
		_rewards_seen.append(encounter)
		_carry_hp.clear()
		for player in view.players:
			_carry_hp.append(player.hp)
	if view.reward_submitted:
		return view.reward_options.is_empty()
	var reward_ids := PackedStringArray()
	for card in view.reward_options:
		reward_ids.append(card.id)
	return reward_ids == PackedStringArray(REWARDS)


func _drive() -> void:
	if not _session.can_submit() or _probe_result >= 0:
		return
	var view := _session.snapshot
	if view.run_stage == "reward":
		_drive_reward(view)
		return
	if view.encounter_id == 1 and view.revision < 3:
		if _seat == 2:
			if view.revision < 2:
				(_combat().get_node("%EndTurnButton") as Button).pressed.emit()
			elif not _probed_target:
				_probed_target = true
				_probe(view, Authority.Result.ILLEGAL_ACTION, Authority.Command.PLAY_CARD,
					{"copy": _find_attack(view), "target": "invalid"})
			else:
				_play(view, _find_attack(view), "slime_2")
		return
	if not view.can_end_turn or not _is_active_seat(view):
		return
	var first_round: bool = view.encounter_id == 1 and view.round == 1
	if not first_round:
		var attack := _find_attack(view)
		var target := _choose_target(view)
		var player: Dictionary = view.players[_seat - 1]
		var incoming := 0
		for enemy in view.enemies:
			if enemy.alive and enemy.intent.kind == EnemyAction.Kind.ATTACK:
				incoming += enemy.intent.amount
		var defense := _find_defense(view)
		if defense >= 0 and incoming - player.block >= player.hp:
			_play(view, defense)
			return
		if attack >= 0:
			_play(view, attack, target)
			return
		if defense >= 0 and incoming > player.block:
			_play(view, defense)
			return
	(_combat().get_node("%EndTurnButton") as Button).pressed.emit()


func _drive_reward(view: Dictionary) -> void:
	if view.reward_ready != _seat - 1 or view.reward_submitted:
		return
	if _seat == 2 and view.encounter_id == 2 and not _probed_old_reward:
		_probed_old_reward = true
		_probe(view, Authority.Result.STALE_TURN, Authority.Command.REWARD,
			{"encounter_id": 1, "reward_id": "shieldstrike"})
		return
	if view.encounter_id == _seat:
		var option := _seat - 1
		_deck.append(view.reward_options[option].id)
		var choices := current_scene.get_node("%RewardChoices")
		(choices.get_child(option) as Button).pressed.emit()
	else:
		(current_scene.get_node("%SkipReward") as Button).pressed.emit()


func _is_active_seat(view: Dictionary) -> bool:
	for offset in _size:
		var player: Dictionary = view.players[(offset + view.round - 1) % _size]
		if player.hp > 0 and not player.ended_turn:
			return player.id == _actor
	return false


func _find_attack(view: Dictionary) -> int:
	var basic := -1
	for card in view.hand:
		if card.playable and card.targets_enemy:
			if card.copy >= RUN.starting_deck.size():
				return card.copy
			basic = card.copy
	return basic


func _find_defense(view: Dictionary) -> int:
	for card in view.hand:
		if card.playable and card.id == "arcane_guard":
			return card.copy
	for card in view.hand:
		if card.playable and not card.targets_enemy:
			return card.copy
	return -1


func _choose_target(view: Dictionary) -> String:
	var lowest := 0
	var selected := ""
	for enemy in view.enemies:
		if enemy.alive and (selected.is_empty() or enemy.hp + enemy.block < lowest):
			lowest = enemy.hp + enemy.block
			selected = enemy.id
	return selected


func _play(view: Dictionary, copy_id: int, target := "") -> void:
	var position := _copies(view).find(copy_id)
	if position < 0:
		_fail("Could not find the scripted card in the private hand.")
		return
	var combat := _combat()
	var button := combat.get_node("%HandCards").get_child(position) as Button
	if button.disabled:
		_fail("The expected card is disabled.")
		return
	var live_count := 0
	for enemy in view.enemies:
		live_count += int(enemy.alive)
	_sent_before = view
	_sent_target = target
	button.pressed.emit()
	if target.is_empty() or live_count <= 1:
		return
	if not _session.can_submit() or _session.snapshot.run_revision != view.run_revision:
		_fail("Selecting a card submitted a command before choosing an enemy.")
		return
	var targets := combat.get_node("%EnemyTargets")
	var target_position: int = IDS[view.encounter_id - 1].find(target)
	var enemy_button := targets.get_child(target_position) as Button
	if enemy_button.disabled:
		_fail("The intended living enemy is not selectable.")
		return
	enemy_button.pressed.emit()


func _probe(view: Dictionary, result: int, kind: Authority.Command, fields: Dictionary) -> void:
	_probe_before = view
	_probe_result = result
	# Use the real client RPC, while keeping the session's next legitimate sequence in order.
	_session._next_sequence += 1
	var request := {"actor": view.viewer, "sequence": _session._next_sequence,
		"kind": int(kind), "encounter_id": view.encounter_id}
	if kind != Authority.Command.REWARD:
		request.merge({"round": view.round, "phase": view.phase, "ready_epoch": view.ready_epoch})
	request.merge(fields, true)
	if _session.rpc_id(NetworkSession.SERVER_ID, &"_request_command", request) != OK:
		_fail("Could not transmit an authority check over localhost.")


func _on_result(_sequence: int, result: int) -> void:
	if _probe_result >= 0:
		if result != _probe_result or _session.snapshot != _probe_before:
			_fail("A stale reward or invalid target changed the run.")
		_probe_result = -1
		return
	if result != Authority.Result.ACCEPTED:
		_fail("The host rejected a legal run action.")
		return
	if not _sent_target.is_empty():
		var after := _session.snapshot
		for index in after.enemies.size():
			var previous: Dictionary = _sent_before.enemies[index]
			var enemy: Dictionary = after.enemies[index]
			if enemy.id == _sent_target:
				if enemy.hp + enemy.block >= previous.hp + previous.block:
					_fail("The intended enemy did not take the targeted hit.")
			elif enemy != previous:
				_fail("A different enemy changed during a single-target play.")
	_sent_target = ""


func _copies(view: Dictionary) -> Array[int]:
	var copies: Array[int] = []
	for card in view.hand:
		copies.append(card.copy)
	return copies


func _combat() -> Node:
	return current_scene.get_node("%CombatSlot/Combat")


func _report(view: Dictionary) -> void:
	var stage_label: Label = current_scene.get_node("%RunStage")
	if (view.run_stage != "victory" or "Run Victory" not in stage_label.text
			or _started != [1, 2, 3] or _rewards_seen != [1, 2]
			or _partial_seen != [1, 2] or (_seat == 2 and (not _probed_target or not _probed_old_reward))):
		_fail("The run ended without exercising every required encounter, reward, and result.")
		return
	_finished = true
	print("RESULT Multi-Enemy Short Run Victory · %d public revisions · %s" %
		[_public_digests.size(), "\n".join(_public_digests).sha256_text()])
	while not FileAccess.file_exists(_release_path):
		await create_timer(0.04).timeout
	quit()


func _fail(message: String) -> void:
	_finished = true
	push_error(message)
	quit(1)
