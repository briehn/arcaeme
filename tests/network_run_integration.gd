extends SceneTree

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const NetworkSession = preload("res://scripts/network/network_coop_session.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const CardData = preload("res://scripts/combat/card_data.gd")
const DATA = preload("res://resources/prototype/battle_mage_run.tres")
const VARIETY = preload("res://resources/prototype/enemy_variety_run.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const BLOCK = preload("res://resources/prototype/cards/basic_block.tres")
const PREPARATION = preload("res://resources/prototype/cards/battle_preparation.tres")
const SHIELDSTRIKE = preload("res://resources/prototype/cards/shieldstrike.tres")
const REVERSAL = preload("res://resources/prototype/cards/arcane_reversal.tres")
const GUARD = preload("res://resources/prototype/cards/arcane_guard.tres")
const MENU := "res://scenes/main.tscn"
const NETWORK := "res://scenes/network_coop.tscn"

var _session: NetworkSession
var _scenario: String
var _enemy_variety := false
var _size: int
var _seat: int
var _actor: String
var _barrier: String
var _deck_size: int
var _max_hp: int
var _seated := false
var _finished := false
var _leaving := false
var _overlap_started := false
var _overlap_reported := false
var _overlap_acks := 0
var _overlap_move: String
var _opening_seen := false
var _reward_seen := false
var _boss_seen := false
var _boss_reported := false
var _opening_revision: int
var _opening_hp: Array[int] = []
var _chosen_reward := ""
var _reward_clicked := false
var _reward_sequence := 0
var _reward_probes_reported := false
var _probe_index := 0
var _probe_result := -1
var _probe_revision: int
var _probe_sequence: int
var _variety_revisions := PackedStringArray()
var _drew_reward := false


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 5:
		_fail("Expected scenario, port, party size, seat and barrier prefix.")
		return
	_scenario = args[0]
	_enemy_variety = _scenario.begins_with("enemy-variety-")
	_size = int(args[2])
	_seat = int(args[3])
	_actor = "Battle Mage %d" % _seat
	_barrier = args[4]
	_deck_size = 4 if _scenario == "mixed" else DATA.starting_deck.size()
	_max_hp = 13 if _scenario == "mixed" else DATA.player_max_hp
	create_timer(50).timeout.connect(func(): _fail("Timed out in %s at seat %d (%s)." %
		[_scenario, _seat, _session.message if is_instance_valid(_session) else "opening menu"]))
	if change_scene_to_file(ProjectSettings.get_setting("application/run/main_scene")) != OK:
		_fail("Could not open the configured main scene.")
		return
	await scene_changed
	(current_scene.get_node("%StartNetworkCoopButton") as Button).pressed.emit()
	await scene_changed
	if current_scene.scene_file_path != NETWORK:
		_fail("The main menu did not open the network screen.")
		return
	_session = current_scene.get_node("Session")
	(current_scene.get_node("%Port") as SpinBox).value = int(args[1])
	_session.changed.connect(_observe_session)
	_session.command_result.connect(_observe_result)
	if _seat == 1:
		if _scenario == "mixed":
			_session.run_data = _recovery_fixture()
		var party: OptionButton = current_scene.get_node("%PartySize")
		party.select(party.get_item_index(_size))
		var short_run: CheckBox = current_scene.get_node("%ShortRun")
		if short_run.button_pressed:
			_fail("The short run should be opt-in from the network menu.")
			return
		short_run.button_pressed = true
		if _enemy_variety:
			var variety: CheckBox = current_scene.get_node("%EnemyVarietyRun")
			if variety.button_pressed or variety.disabled or not variety.is_visible_in_tree():
				_fail("The enemy variety route should be an available opt-in after enabling Short Run.")
				return
			variety.button_pressed = true
			if _session.run_data != VARIETY or (_control("%HostButton") as Button).text != "Host Enemy Variety Run":
				_fail("The lobby did not select the actual enemy variety fixture.")
				return
	var launch: Button = current_scene.get_node("%HostButton" if _seat == 1 else "%JoinButton")
	launch.pressed.emit()
	while not _finished:
		_drive()
		await process_frame


func _recovery_fixture() -> RunData:
	var fixture: RunData = DATA.duplicate()
	var opening: EncounterData = DATA.opening_encounters[0].duplicate()
	var boss: EncounterData = DATA.boss_encounter.duplicate()
	var strike: CardData = STRIKE.duplicate()
	var universal: CardData = REVERSAL.duplicate()
	var other_class: CardData = SHIELDSTRIKE.duplicate()
	fixture.player_max_hp = 13
	opening.enemy_max_hp = 6
	opening.enemy_attack = 13
	boss.enemy_max_hp = 6
	strike.is_attack = false
	universal.id = &"test_universal"
	universal.owner_class_id = &"universal"
	other_class.id = &"test_other_class"
	other_class.owner_class_id = &"other_class"
	fixture.opening_encounters = [opening]
	fixture.boss_encounter = boss
	fixture.starting_deck = [strike, BLOCK, BLOCK, PREPARATION]
	fixture.reward_candidates = [universal, SHIELDSTRIKE, other_class, REVERSAL, SHIELDSTRIKE, GUARD]
	return fixture


func _observe_session() -> void:
	if _session.status == NetworkSession.Status.ACTIVE:
		var view := _session.snapshot
		if not _check_private_view(view):
			return
		if _enemy_variety and not _check_variety_view(view):
			return
		if view.run_stage == "opening" and not _opening_seen:
			_opening_seen = _check_opening(view)
		elif view.run_stage == "reward" and not _reward_seen:
			_reward_seen = _check_opening_victory(view) and _check_reward(view)
		if _overlap_started and _seat > 1 and not _overlap_reported and view.revision == 1:
			var own_move := _overlap_move in "\n".join(view.log)
			if _session.can_submit() != own_move or _overlap_acks != int(own_move):
				_fail("A client's unrelated broadcast cleared or acknowledged its pending action.")
	if _seated or _session.status not in [NetworkSession.Status.HOSTING, NetworkSession.Status.WAITING]:
		return
	var roster_label: Label = current_scene.get_node("%PartyRoster")
	if _session.local_player != _actor or _session.party_size != _size or \
			_session.connected_players.size() != _seat or "%d/%d connected" % [_seat, _size] not in roster_label.text or \
			not _session.snapshot.is_empty() or _session.can_submit() or _control("%CombatSlot").visible:
		_fail("Waiting lobby exposed combat or assigned an unexpected seat.")
		return
	_seated = true
	print("SEAT_READY ", _seat)


func _observe_result(sequence: int, result: int) -> void:
	if _probe_result != -1:
		if result != _probe_result or sequence != _probe_sequence or _session.snapshot.run_revision != _probe_revision:
			_fail("Probe %d expected %s at revision %d, received %s at revision %d." % [
				_probe_index, Authority.Result.keys()[_probe_result], _probe_revision,
				Authority.Result.keys()[result], _session.snapshot.run_revision])
			return
		_probe_result = -1
		_probe_index += 1
	elif result != Authority.Result.ACCEPTED:
		_fail("An ordinary command was rejected (%s)." % Authority.Result.keys()[result])
	elif _reward_clicked and _reward_sequence == 0:
		_reward_sequence = sequence
	elif _overlap_started and not _overlap_reported:
		_overlap_acks += 1


func _drive() -> void:
	if _leaving:
		return
	if _session.status == NetworkSession.Status.DISCONNECTED:
		_report_disconnect()
		return
	if _scenario == "lobby-disconnect" and _seat == 2 and _seated:
		_leave()
		return
	if _session.status != NetworkSession.Status.ACTIVE:
		return
	var view := _session.snapshot
	match view.run_stage:
		"opening":
			if _scenario == "skip" and not _released("continue-opening"):
				_drive_overlap(view)
			else:
				_drive_combat(view)
		"reward":
			_drive_reward(view)
		"boss":
			_drive_boss(view)
		"victory", "defeat":
			_report_outcome(view)
		_:
			_fail("Unexpected network run stage.")


func _check_private_view(view: Dictionary) -> bool:
	if not _seated or view.viewer != _actor or view.players.size() != _size or view.has("seed") or \
			"Seed" in "\n".join(view.log) or view.has("reward_offers_by_player"):
		_fail("The network view exposed private data or showed the wrong viewer or party.")
		return false
	for index in _size:
		var player: Dictionary = view.players[index]
		if player.id != "Battle Mage %d" % (index + 1) or player.has("hand") or player.has("deck") or \
				player.has("draw_pile") or player.has("discard_pile") or player.has("run_deck_count") or \
				player.has("reward_options") or player.has("reward_id") or player.has("selected_reward"):
			_fail("The public roster exposed a player's private cards or had the wrong seat order.")
			return false
	return true


func _check_variety_view(view: Dictionary) -> bool:
	var encounter: EncounterData = VARIETY.opening_encounters[0] if view.encounter_id == 1 else VARIETY.boss_encounter
	var pattern := encounter.enemy_attack_pattern
	var expected_attack := pattern[(int(view.round) - 1) % pattern.size()]
	var stage_label: Label = _control("%RunStage")
	if (view.get("run_title") != VARIETY.title or VARIETY.title not in stage_label.text
			or view.enemy_name != encounter.enemy_name or view.enemy_attack != expected_attack):
		_fail("The alternative route title, enemy, or advertised intent did not survive the host snapshot.")
		return false
	if view.phase == CombatState.Phase.PLAYER:
		var enemy_label: Label = _combat().get_node("%EnemyLabel")
		if ("Attack all living players for %d damage each" % expected_attack) not in enemy_label.text:
			_fail("The visible intent does not match the advertised pattern amount.")
			return false
	var attacks := 0
	for entry in view.log:
		if entry.begins_with(encounter.enemy_name + " attacks for "):
			if entry != "%s attacks for %d damage." % [encounter.enemy_name, pattern[attacks % pattern.size()]]:
				_fail("Resolved attacks diverged from the enemy's pattern.")
				return false
			attacks += 1
	if view.phase != CombatState.Phase.DEFEAT and attacks != view.round - 1:
		_fail("An attack resolved early or a previous round's attack is missing.")
		return false
	var expected_deck_count := _deck_size + int(view.encounter_id == 2 and not _chosen_reward.is_empty())
	if not _check_hand_ids(view, expected_deck_count):
		return false
	for card in view.hand:
		var copy: int = card.copy
		var expected_id := _chosen_reward if copy == _deck_size else String(VARIETY.starting_deck[copy].id)
		if card.id != expected_id:
			_fail("The private hand diverged from this player's starting deck and chosen reward.")
			return false
		_drew_reward = _drew_reward or copy == _deck_size
	if view.run_revision > _variety_revisions.size():
		_fail("A peer missed a public run revision.")
		return false
	if view.run_revision == _variety_revisions.size():
		_variety_revisions.append(JSON.stringify([_public_digest(view), view.run_title, view.enemy_name,
			view.enemy_attack, view.get("reward_ready", -1)]))
	return true


func _check_opening(view: Dictionary) -> bool:
	var opening: EncounterData = VARIETY.opening_encounters[0] if _enemy_variety else DATA.opening_encounters[0]
	var enemy_hp := 6 if _scenario == "mixed" else opening.enemy_max_hp
	if view.encounter_id != 1 or view.revision != 0 or view.run_revision != 0 or view.round != 1 or \
			view.enemy_name != opening.enemy_name or view.enemy_hp != enemy_hp or \
			view.run_deck_count != _deck_size or view.has("reward_options") or \
			not _control("%CombatSlot").visible or _control("%RewardPanel").visible:
		_fail("The configured opening encounter or fresh starting deck was not shown.")
		return false
	if not _check_hand_ids(view, _deck_size):
		return false
	for player in view.players:
		if player.hp != _max_hp or player.max_hp != _max_hp:
			_fail("The opening used the wrong player HP.")
			return false
	return true


func _drive_overlap(view: Dictionary) -> void:
	if not _overlap_started and _seat == 1:
		multiplayer_poll = false
		_overlap_started = true
		print("OVERLAP_HOST_READY")
	elif not _overlap_started and _released("send-overlap"):
		var card: Dictionary = view.hand[0]
		_overlap_move = "%s played %s" % [_actor, card.name]
		if view.revision != 0 or not _play_card(card):
			_fail("Both clients must send a legal card from encounter revision zero.")
			return
		if _session.can_submit() or _session.snapshot.revision != 0:
			_fail("The client applied a command before receiving host confirmation.")
			return
		_overlap_started = true
		print("OVERLAP_SENT 0")
	if _seat == 1 and _released("resolve-overlap"):
		multiplayer_poll = true
	if view.revision < 2 or _overlap_reported:
		return
	var plays := PackedStringArray()
	for entry in view.log:
		if " played " in entry:
			plays.append(entry)
	if view.revision != 2 or plays.size() != 2 or not (
			plays[0].begins_with("Battle Mage 2 ") and plays[1].begins_with("Battle Mage 3 ") or
			plays[0].begins_with("Battle Mage 3 ") and plays[1].begins_with("Battle Mage 2 ")) or \
					(_seat > 1 and (_overlap_acks != 1 or not _session.can_submit())):
		_fail("The host did not apply and acknowledge both overlapping plays once.")
		return
	_overlap_reported = true
	print("OVERLAP_STATE ", _public_digest(view))


func _drive_combat(view: Dictionary) -> void:
	if not _session.can_submit() or not view.can_end_turn:
		return
	for player in view.players:
		if player.hp > 0 and not player.ended_turn:
			if player.id != _actor:
				return
			break

	if _scenario == "mixed" and view.run_stage == "opening":
		if _seat == 1 and view.round == 1 and view.players[0].block < 10:
			_play_by_id(view, "basic_block")
			return
		if view.round > 1:
			_play_by_id(view, "battle_preparation" if view.players[0].next_attack_bonus == 0 else "basic_strike")
			return
	elif _enemy_variety and view.round <= 2:
		# Let both enemy cycles reach their third advertised step. The host blocks to produce unequal carried HP.
		if (_seat == 1 or view.run_stage == "boss") and view.players[_seat - 1].block < view.enemy_attack:
			for card in view.hand:
				if card.playable and card.id in ["basic_block", "arcane_guard", "battle_preparation"]:
					_play_card(card)
					return
	else:
		var deal_damage: bool = view.run_stage == "boss" and _scenario != "skip" or \
				view.run_stage == "opening" and (_scenario == "skip" or view.round > 1)
		if deal_damage:
			for card in view.hand:
				if (card.attack or card.id == "basic_strike") and card.playable:
					_play_card(card)
					return
	var end: Button = _combat().get_node("%EndTurnButton")
	if end.disabled or not end.is_visible_in_tree():
		_fail("End Turn is unavailable for an active player.")
		return
	end.pressed.emit()


func _play_by_id(view: Dictionary, card_id: String) -> void:
	for card in view.hand:
		if card.id == card_id and card.playable:
			_play_card(card)
			return
	_fail("Missing playable %s at round %d." % [card_id, view.round])


func _play_card(card: Dictionary) -> bool:
	for child in _combat().get_node("%HandCards").get_children():
		var button := child as Button
		if not button.disabled and button.is_visible_in_tree() and button.text.begins_with(card.name + "\n"):
			button.pressed.emit()
			return true
	_fail("Missing card button for %s." % card.name)
	return false


func _check_opening_victory(view: Dictionary) -> bool:
	_opening_revision = view.revision
	for player in view.players:
		_opening_hp.append(player.hp)
	if not _opening_seen or view.phase != CombatState.Phase.VICTORY or view.encounter_id != 1 or view.enemy_hp != 0 or \
			_opening_revision < 1 or view.reward_ready != 0:
		_fail("The reward phase did not follow the opening victory.")
		return false
	if _scenario == "mixed":
		if _opening_hp != [10, 4, 4, 4] or view.players[0].next_attack_bonus <= 0 or view.players[0].block <= 0:
			_fail("The recovery fixture did not produce an injured survivor, recovered teammates and pending modifiers.")
			return false
		for index in _size:
			if view.players[index].recovered != (index > 0):
				_fail("Opening recovery flags identified the wrong players.")
				return false
	elif _enemy_variety and (view.round < 3 or _opening_hp[0] <= _opening_hp[1]):
		_fail("The opening did not demonstrate the Goblin cycle and distinguish carried HP by seat.")
		return false
	return true


func _drive_reward(view: Dictionary) -> void:
	if not _check_reward(view):
		return
	if _scenario == "reward-disconnect" and view.reward_ready == 1 and _seat == 2:
		_leave()
		return
	if _scenario == "mixed":
		if _seat == 2 and _drive_reward_probes(view):
			return
		if view.reward_ready > 0 and not _released("continue-rewards"):
			return
	var order := [2, 1, 3, 4] if _scenario == "mixed" else [1, 2, 3, 4]
	if _reward_clicked or view.reward_submitted or order[view.reward_ready] != _seat or \
			(_scenario == "reward-disconnect" and view.reward_ready > 0):
		return
	if _scenario == "take" or ((_scenario == "mixed" or _enemy_variety) and _seat % 2 == 0):
		var index := (_seat - 1) % (view.reward_options as Array).size()
		_chosen_reward = view.reward_options[index].id
		_reward_clicked = true
		var button := _control("%RewardChoices").get_child(index) as Button
		button.pressed.emit()
	else:
		_reward_clicked = true
		(_control("%SkipReward") as Button).pressed.emit()


func _check_reward(view: Dictionary) -> bool:
	var label: Label = current_scene.get_node("%RewardProgress")
	var choices := _control("%RewardChoices")
	var skip := _control("%SkipReward") as Button
	if view.reward_ready < 0 or view.reward_ready >= _size or not _control("%RewardPanel").visible or \
			_control("%CombatSlot").visible or "%d/%d" % [view.reward_ready, _size] not in label.text:
		_fail("Reward progress or reward/combat panel visibility is incorrect.")
		return false
	if view.reward_submitted:
		if not view.reward_options.is_empty() or choices.get_child_count() != 0 or skip.is_visible_in_tree():
			_fail("A settled player can still see or use reward choices.")
			return false
		return true
	var expected := ["shieldstrike", "arcane_reversal", "arcane_guard"]
	var ids: Array[String] = []
	if choices.get_child_count() != view.reward_options.size() or not skip.is_visible_in_tree():
		_fail("The private reward buttons do not match the received options.")
		return false
	for index in view.reward_options.size():
		var option: Dictionary = view.reward_options[index]
		var button := choices.get_child(index) as Button
		if option.id not in expected or option.id in ids or option.size() != 4 or \
				option.name not in button.text or option.description not in button.text or \
				"%d Mana" % option.cost not in button.text:
			_fail("A reward offer leaked extra data, duplicated a card, included an ineligible card or rendered incorrectly.")
			return false
		ids.append(option.id)
	if ids.size() != expected.size():
		_fail("The viewer did not receive every eligible reward.")
		return false
	return true


func _drive_reward_probes(view: Dictionary) -> bool:
	if _probe_result != -1:
		return true
	if _probe_index == 0:
		_probe(view, Authority.Result.WRONG_PLAYER, {"actor": "Battle Mage 1", "sequence": 8000,
			"encounter_id": 1, "kind": int(Authority.Command.REWARD), "reward_id": ""})
		return true
	if not view.reward_submitted:
		return false
	if _probe_index in [1, 2]:
		var sequence := _reward_sequence if _probe_index == 1 else _reward_sequence + 1
		var expected := Authority.Result.DUPLICATE if _probe_index == 1 else Authority.Result.ILLEGAL_ACTION
		_probe(view, expected, {"actor": _actor, "sequence": sequence, "encounter_id": 1,
			"kind": int(Authority.Command.REWARD), "reward_id": _chosen_reward})
	elif not _reward_probes_reported:
		_reward_probes_reported = true
		print("REWARD_PROBES_DONE")
	return true


func _probe(view: Dictionary, expected: int, request: Dictionary) -> void:
	_probe_result = expected
	_probe_revision = view.run_revision
	_probe_sequence = request.sequence
	if _session.rpc_id(NetworkSession.SERVER_ID, &"_request_command", request) != OK:
		_fail("Could not send the regression probe.")


func _drive_boss(view: Dictionary) -> void:
	if not _boss_seen:
		if not _check_boss_start(view):
			return
		_boss_seen = true
	if _scenario == "mixed" and _seat == 2 and _probe_index < 5:
		if _probe_result == -1:
			var request := {"actor": _actor, "sequence": _reward_sequence + _probe_index - 1, "encounter_id": 1}
			if _probe_index == 3:
				request.merge({"kind": int(Authority.Command.REWARD), "reward_id": _chosen_reward})
			else:
				request.merge({"kind": int(Authority.Command.END_TURN), "round": view.round, "phase": view.phase})
			_probe(view, Authority.Result.STALE_TURN, request)
		return
	if not _boss_reported:
		_boss_reported = true
		print("BOSS_READY ", _public_digest(view))
	if _released("continue-boss"):
		_drive_combat(view)


func _check_boss_start(view: Dictionary) -> bool:
	var run: RunData = VARIETY if _enemy_variety else DATA
	var enemy_hp := 6 if _scenario == "mixed" else run.boss_encounter.enemy_max_hp
	var expected_deck_size := _deck_size + int(not _chosen_reward.is_empty())
	var stage_label: Label = current_scene.get_node("%RunStage")
	var stage_title := "Final Encounter" if _enemy_variety else "Boss"
	if not _reward_seen or not _reward_clicked or view.encounter_id != 2 or view.revision != 0 or \
			view.run_revision != _opening_revision + _size or view.round != 1 or view.phase != CombatState.Phase.PLAYER or \
			view.enemy_name != run.boss_encounter.enemy_name or view.enemy_hp != enemy_hp or \
			view.run_deck_count != expected_deck_size or view.discard_count != 0 or \
			view.hand.size() != mini(5, expected_deck_size) or view.hand.size() + view.draw_count != expected_deck_size or \
			view.has("reward_options") or run.opening_encounters[0].enemy_name in "\n".join(view.log) or \
			not _control("%CombatSlot").visible or _control("%RewardPanel").visible or stage_title not in stage_label.text:
		_fail("The fresh boss snapshot carried the wrong encounter ID, revision, deck, combat state or UI.")
		return false
	if not _check_hand_ids(view, expected_deck_size):
		return false
	for index in _size:
		var player: Dictionary = view.players[index]
		if player.hp != _opening_hp[index] or player.max_hp != _max_hp or player.block != 0 or player.mana != 3 or \
				player.next_attack_bonus != 0 or player.ended_turn or player.recovered:
			_fail("The boss did not carry each player's HP while resetting combat-only fields.")
			return false
	if _scenario == "mixed":
		var boss_ids: Array[String] = []
		for card in view.hand:
			if card.id != "basic_strike" and card.id != "basic_block" and card.id != "battle_preparation":
				boss_ids.append(card.id)
		if boss_ids != ([] if _chosen_reward.is_empty() else [_chosen_reward]):
			_fail("The boss hand did not contain exactly this player's chosen card.")
			return false
	return true


func _check_hand_ids(view: Dictionary, deck_size: int) -> bool:
	var copy_ids: Array[int] = []
	for card in view.hand:
		if card.copy < 0 or card.copy >= deck_size or card.copy in copy_ids:
			_fail("The private hand did not use unique seat-local card copy IDs.")
			return false
		copy_ids.append(card.copy)
	return true


func _report_outcome(view: Dictionary) -> void:
	var expected := "defeat" if _scenario == "skip" else "victory"
	var expected_phase := CombatState.Phase.DEFEAT if expected == "defeat" else CombatState.Phase.VICTORY
	var label: Label = current_scene.get_node("%RunStage")
	var title := "Run Defeat" if expected == "defeat" else "Run Victory"
	if (_scenario not in ["take", "skip", "mixed"] and not _enemy_variety) or not _boss_reported or view.encounter_id != 2 or \
			view.run_stage != expected or view.phase != expected_phase or title not in label.text or \
			not (_combat().get_node("%EndTurnButton") as Button).disabled or _control("%RewardPanel").visible:
		_fail("Unexpected terminal run state or active UI at the end of the run.")
		return
	for player in view.players:
		if (player.hp == 0) != (expected == "defeat"):
			_fail("Terminal HP disagrees with the reported party outcome.")
			return
	if _enemy_variety:
		if view.round < 3 or (not _chosen_reward.is_empty() and not _drew_reward):
			_fail("The party concluded before exercising the Treant cycle and drawing the chosen private reward.")
			return
		var carried_hp := PackedStringArray()
		var final_hp := PackedStringArray()
		for index in _size:
			carried_hp.append(str(_opening_hp[index]))
			final_hp.append(str(view.players[index].hp))
		_report("%s · Goblin to Treant · round %d · HP carried %s · final %s · %s" % [
			title, view.round, "/".join(carried_hp), "/".join(final_hp), "\n".join(_variety_revisions).sha256_text()])
	else:
		_report("%s · encounter %d · round %d · %s" % [title, view.encounter_id, view.round, _public_digest(view)])


func _report_disconnect() -> void:
	var view := _session.snapshot
	if _scenario not in ["lobby-disconnect", "reward-disconnect"] or "disconnected" not in _session.message or \
			root.multiplayer.has_multiplayer_peer() or _session.can_submit() or _session.submit_end_turn() or \
			_control("%CombatSlot").visible:
		_fail("Disconnect failed to release the transport or disable the run.")
		return
	if _scenario == "lobby-disconnect" and not view.is_empty() or \
			_scenario == "reward-disconnect" and (not _reward_seen or view.run_stage != "reward" or \
			view.reward_ready != 1 or _session.submit_reward("")):
		_fail("Disconnect advanced the incomplete lobby or unresolved reward phase.")
		return
	_report(_scenario)


func _leave() -> void:
	_leaving = true
	(_control("%LeaveButton") as Button).pressed.emit()
	await scene_changed
	if current_scene.scene_file_path != MENU or root.multiplayer.has_multiplayer_peer():
		_fail("Leaving did not return to the main menu and release the transport.")
		return
	_report(_scenario)


func _public_digest(view: Dictionary) -> String:
	return JSON.stringify({"players": view.players, "phase": view.phase, "round": view.round,
		"enemy_hp": view.enemy_hp, "run_stage": view.run_stage, "encounter_id": view.encounter_id,
		"revision": view.revision, "run_revision": view.run_revision, "log": view.log}).sha256_text()


func _combat() -> Node:
	return _control("%CombatSlot").get_node("Combat")


func _control(path: NodePath) -> Control:
	return current_scene.get_node(path) as Control


func _released(name: String) -> bool:
	return FileAccess.file_exists(_barrier + "." + name)


func _report(message: String) -> void:
	_finished = true
	print("RESULT ", message)
	while not _released("finish"):
		await create_timer(0.04).timeout
	quit()


func _fail(message: String) -> void:
	_finished = true
	push_error(message)
	quit(1)
