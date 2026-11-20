extends SceneTree

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const CardData = preload("res://scripts/combat/card_data.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const CoopRunState = preload("res://scripts/run/coop_run_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const RunState = preload("res://scripts/run/run_state.gd")
const ROUTE = preload("res://resources/prototype/multi_enemy_run.tres")
const ORIGINAL = preload("res://resources/prototype/battle_mage_run.tres")
const SLIMES = preload("res://resources/prototype/enemies/two_slimes.tres")
const GOBLIN_TREANT = preload("res://resources/prototype/enemies/goblin_treant.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const SOLO := RunState.PLAYER_ID
const HOST := &"Battle Mage 1"
const ALLY := &"Battle Mage 2"
const SEATS: Array[StringName] = [HOST, ALLY]

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_check(ROUTE.encounter_count() == 3 and ROUTE.opening_encounters == [SLIMES]
		and ROUTE.intermediate_encounters == [GOBLIN_TREANT], "the opt-in route uses both established normal encounters in order")
	_check(ROUTE.boss_encounter.enemies.size() <= 1 and ROUTE.boss_encounter.enemy_id == &"citadel_warden"
		and ROUTE.boss_encounter.enemy_max_hp == ORIGINAL.boss_encounter.enemy_max_hp
		and ROUTE.boss_encounter.enemy_attack == ORIGINAL.boss_encounter.enemy_attack,
		"Citadel Warden remains the established single-enemy boss")
	_check(ROUTE.starting_deck == ORIGINAL.starting_deck and ROUTE.reward_candidates == ORIGINAL.reward_candidates,
		"the existing starting deck and class reward candidates are reused")
	_test_solo_progression()
	_test_run_defeat()
	_test_coop_progression()
	_test_authority_settlement()
	print("Multi-enemy run: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _test_solo_progression() -> void:
	var run := RunState.new(ROUTE)
	var first_reward: CardData = ROUTE.reward_candidates[0]
	var second_reward: CardData = ROUTE.reward_candidates[1]
	_check(run.encounter_id == 0 and not run.choose_opening(&"goblin_treant") and not run.start_next_encounter(),
		"only the configured opening is selectable")
	_check(run.choose_opening(SLIMES.enemy_id) and run.encounter_id == 1 and run.stage == RunState.Stage.OPENING_COMBAT,
		"enter Two Slimes as encounter one")
	var opening := run.active_combat
	var player := opening.players[SOLO]
	player.hp = 23
	player.poison = 2
	player.burning = 3
	player.block = 9
	player.strength = 2
	player.dexterity = 4
	player.next_attack_bonus = 5
	opening.enemies[0].hp = 1
	opening.enemies[1].hp = 1
	var strike_copy := _strike_copy(opening, SOLO)
	_check(opening.play_card(SOLO, strike_copy, opening.enemies[1].id)
		and opening.enemies[0].hp == 1 and opening.phase == CombatState.Phase.PLAYER,
		"selecting the second Slime kills only its instance and keeps the fight active")
	_check(not run.finish_combat(opening) and run.reward_options().is_empty(), "a partial victory cannot produce a reward")
	_check(not opening.play_card(SOLO, _strike_copy(opening, SOLO), opening.enemies[1].id)
		and player.mana == 2 and opening.action_history.size() == 1,
		"a defeated target consumes neither the second strike nor Mana")
	_check(opening.play_card(SOLO, _strike_copy(opening, SOLO), opening.enemies[0].id)
		and run.finish_combat(opening) and run.stage == RunState.Stage.REWARD and run.current_hp == 23,
		"defeating both Slimes opens reward one and captures remaining HP")
	_check(run.next_encounter() == GOBLIN_TREANT and not run.start_next_encounter() and not run.finish_combat(opening),
		"the current reward must settle before the second encounter")
	_check(run.take_reward(first_reward.id) and run.stage == RunState.Stage.NEXT_READY
		and run.deck_cards() == ROUTE.starting_deck + [first_reward] and not run.skip_reward(),
		"settle reward one exactly once and append only the chosen card")
	_check(not run.start_boss() and run.start_next_encounter() and run.encounter_id == 2
		and run.stage == RunState.Stage.INTERMEDIATE_COMBAT, "advance into the intermediate fight without skipping it")
	var middle := run.active_combat
	_check(_fresh(middle, SOLO, 23, ROUTE.starting_deck.size() + 1)
		and _ids(middle) == [&"goblin", &"treant"] and middle.card_data(ROUTE.starting_deck.size()) == first_reward,
		"second fight has fresh combat state and carries opening HP and reward copy")
	middle.players[SOLO].hp = 16
	_win(middle, SOLO)
	_check(run.finish_combat(middle) and run.encounter_id == 2 and run.stage == RunState.Stage.REWARD
		and run.next_encounter() == ROUTE.boss_encounter, "only the second full victory opens reward two")
	_check(run.take_reward(second_reward.id) and run.stage == RunState.Stage.BOSS_READY
		and run.deck_cards() == ROUTE.starting_deck + [first_reward, second_reward]
		and run.reward_choices() == [first_reward.id, second_reward.id], "both takes build one persistent ordered deck and history")
	_check(run.start_boss() and run.encounter_id == 3 and run.stage == RunState.Stage.BOSS_COMBAT, "start the final boss")
	var boss := run.active_combat
	var deck_count := ROUTE.starting_deck.size() + 2
	_check(_fresh(boss, SOLO, 16, deck_count) and _ids(boss) == [&"citadel_warden"]
		and boss.card_data(deck_count - 2) == first_reward and boss.card_data(deck_count - 1) == second_reward,
		"boss starts with carried HP and both reward copies")
	_win(boss, SOLO)
	_check(run.finish_combat(boss) and run.stage == RunState.Stage.VICTORY and run.reward_options().is_empty()
		and not run.start_next_encounter() and not run.finish_combat(boss), "final victory ends the run without another reward")


func _test_run_defeat() -> void:
	var run := RunState.new(ROUTE)
	run.choose_opening(SLIMES.enemy_id)
	_win(run.active_combat, SOLO)
	run.finish_combat(run.active_combat)
	_check(run.skip_reward() and run.deck_cards() == ROUTE.starting_deck and run.start_next_encounter(),
		"skipping the first reward preserves the deck")
	_check(run.reward_choices() == [&""], "the solo reward history keeps a skip")
	var combat := run.active_combat
	combat.players[SOLO].hp = 1
	combat.players[SOLO].burning = 1
	combat.end_turn(SOLO)
	_check(run.finish_combat(combat) and run.stage == RunState.Stage.DEFEAT and run.encounter_id == 2
		and run.current_hp == 0 and not run.skip_reward() and not run.start_next_encounter(),
		"a second-encounter defeat ends the run without reward or boss")


func _test_coop_progression() -> void:
	var data: RunData = ROUTE.duplicate()
	data.player_max_hp = 37
	var run := CoopRunState.new(data, SEATS)
	var combat := run.active_combat
	combat.players[HOST].hp = 26
	combat.players[ALLY].hp = 0
	_win(combat, HOST)
	run.observe_combat_result()
	var host_reward: CardData = data.reward_candidates[0]
	var ally_reward: CardData = data.reward_candidates[1]
	_check(combat.players[ALLY].recovered_after_victory and combat.players[ALLY].hp == 10
		and run.stage == CoopRunState.REWARD and run.view_fields(ALLY).reward_options.size() == data.reward_candidates.size(),
		"defeated teammate recovers rounded up and receives a personal reward")
	_check(run.submit_reward(HOST, host_reward.id) and not run.submit_reward(HOST, &"")
		and not run.submit_reward(&"unknown", &"") and run.encounter_id == 1 and run.active_combat == combat,
		"the team waits for the ally and the host cannot claim twice")
	var host_view := run.view_fields(HOST)
	var ally_view := run.view_fields(ALLY)
	_check(host_view.reward_ready == 1 and ally_view.reward_ready == 1 and host_view.reward_submitted
		and host_view.reward_options.is_empty() and not ally_view.reward_submitted
		and ally_view.next_encounter_name == GOBLIN_TREANT.enemy_name and ally_view.run_deck_count == data.starting_deck.size(),
		"readiness is shared and reward choices and deck counts are scoped to the viewing seat")
	_check(run.submit_reward(ALLY, &"") and run.stage == CoopRunState.INTERMEDIATE and run.encounter_id == 2,
		"the last private decision advances to the middle fight")
	var middle := run.active_combat
	_check(_fresh(middle, HOST, 26, data.starting_deck.size() + 1)
		and _fresh(middle, ALLY, 10, data.starting_deck.size()), "health, recovery and asymmetric decks carry into fresh combat")
	var first_hand := middle.players[HOST].hand.duplicate()
	_check(middle.end_turn(HOST) and middle.players[HOST].hand == first_hand
		and middle.undo_ready(HOST) and middle.players[HOST].hand == first_hand, "Ready and Undo preserve hands in the second fight")
	middle.players[ALLY].hp = 0
	middle.players[HOST].hp = 14
	_win(middle, HOST)
	run.observe_combat_result()
	_check(run.view_fields(HOST).reward_ready == 0 and run.view_fields(ALLY).next_encounter_name == ROUTE.boss_encounter.enemy_name
		and run.view_fields(HOST).reward_options.size() == data.reward_candidates.size(),
		"reward two starts a fresh barrier and announces Citadel Warden")
	_check(run.submit_reward(ALLY, ally_reward.id) and run.submit_reward(HOST, &"") and run.stage == CoopRunState.BOSS
		and run.encounter_id == 3, "both seats can now make new and different decisions")
	var boss := run.active_combat
	_check(_fresh(boss, HOST, 14, data.starting_deck.size() + 1) and _fresh(boss, ALLY, 10, data.starting_deck.size() + 1)
		and run.deck_cards(HOST) == data.starting_deck + [host_reward]
		and run.deck_cards(ALLY) == data.starting_deck + [ally_reward],
		"boss carries only the correct player's take and skip choices")
	_check(run.reward_choices(HOST) == [host_reward.id, &""] and run.reward_choices(ALLY) == [&"", ally_reward.id],
		"private history tracks each seat's takes and skips in encounter order")
	run.deck_cards(HOST).clear()
	run.reward_choices(HOST).clear()
	_check(run.deck_cards(HOST).size() == data.starting_deck.size() + 1 and run.reward_choices(HOST).size() == 2,
		"deck and reward history projections cannot mutate run state")
	boss.players[HOST].hp = 0
	boss.players[ALLY].hp = 1
	boss.end_turn(ALLY)
	run.observe_combat_result()
	_check(run.stage == CoopRunState.DEFEAT and not run.submit_reward(HOST, &""),
		"a party wipe on the boss ends the run without rewards, and a defeated seat never blocks phase closure")


func _test_authority_settlement() -> void:
	var fixture := _authority_fixture()
	var authority := Authority.new(fixture.opening_encounters[0], {1: HOST, 20: ALLY}, fixture)
	var first := authority.snapshot_for(1)
	_check(first.encounter_id == 1 and first.encounter_count == 3 and first.run_revision == 0, "the host projects route identity and progress")
	_authority_play(authority, 1, 1, String(first.enemies[0].id))
	var partial := authority.snapshot_for(1)
	_check(partial.run_stage == CoopRunState.OPENING and partial.enemies[1].hp == 1 and not partial.has("reward_options"),
		"the first valid target is independent and an early kill does not publish a reward")
	_authority_play(authority, 1, 2, String(first.enemies[1].id))
	var reward_one := authority.snapshot_for(1)
	var ally_reward_one := authority.snapshot_for(20)
	_check(reward_one.run_stage == CoopRunState.REWARD and reward_one.run_revision == 2
		and reward_one.reward_options.size() == ROUTE.reward_candidates.size(), "only eligible Battle Mage offers are published")
	var host_choice := _reward(reward_one, 3, String(ROUTE.reward_candidates[0].id))
	_check(authority.submit(20, host_choice) == Authority.Result.WRONG_PLAYER, "another peer cannot submit the host's reward")
	_check(authority.submit(1, host_choice) == Authority.Result.ACCEPTED
		and authority.submit(1, host_choice) == Authority.Result.DUPLICATE, "duplicate reward requests settle only once")
	var host_waiting := authority.snapshot_for(1)
	var ally_waiting := authority.snapshot_for(20)
	_check(host_waiting.run_deck_count == 6 and ally_waiting.run_deck_count == 5 and host_waiting.reward_options.is_empty()
		and ally_waiting.reward_options == ally_reward_one.reward_options and host_waiting.players == ally_waiting.players
		and not host_waiting.players[0].has("reward_options") and not host_waiting.players[0].has("hand")
		and not host_waiting.has("reward_choices") and not ally_waiting.has("reward_choices"),
		"only viewer-private data reveals the settled offer or deck change")
	_check(authority.submit(20, _reward(ally_waiting, 1, "")) == Authority.Result.ACCEPTED, "the ally's skip settles reward one")
	var middle := authority.snapshot_for(1)
	_check(middle.encounter_id == 2 and middle.run_stage == CoopRunState.INTERMEDIATE and middle.revision == 0
		and middle.run_revision == 4 and not middle.has("reward_options"), "encounter revisions reset while run revision advances")
	var stale_combat := _play_request(first, 4, String(first.enemies[0].id))
	_check(authority.submit(1, stale_combat) == Authority.Result.STALE_TURN
		and authority.snapshot_for(1) == middle, "a command from the prior encounter cannot use a reused round or copy")
	_authority_play(authority, 1, 5, String(middle.enemies[0].id))
	_authority_play(authority, 1, 6, String(middle.enemies[1].id))
	var reward_two := authority.snapshot_for(1)
	_check(reward_two.encounter_id == 2 and reward_two.run_stage == CoopRunState.REWARD
		and reward_two.run_revision == 6 and reward_two.reward_ready == 0
		and reward_two.next_encounter_name == "Citadel Warden", "the second complete win opens only its own reward window")
	var stale_reward := host_choice.duplicate()
	stale_reward.sequence = 7
	_check(authority.submit(1, stale_reward) == Authority.Result.STALE_TURN
		and authority.snapshot_for(1) == reward_two, "a late reward one command cannot claim reward two")
	_check(authority.submit(1, _reward(reward_two, 8, "")) == Authority.Result.ACCEPTED
		and authority.submit(20, _reward(authority.snapshot_for(20), 2, String(ROUTE.reward_candidates[1].id))) == Authority.Result.ACCEPTED,
		"independent decisions settle the second barrier")
	var boss := authority.snapshot_for(1)
	var ally_boss := authority.snapshot_for(20)
	_check(boss.encounter_id == 3 and boss.revision == 0 and boss.run_revision == 8 and boss.enemies.size() == 1
		and boss.enemies[0].id == "citadel_warden" and boss.run_deck_count == 6 and ally_boss.run_deck_count == 6
		and boss.enemies == ally_boss.enemies and boss.players == ally_boss.players, "both views agree on the fresh final boss")
	_authority_play(authority, 1, 9, String(boss.enemies[0].id))
	var final := authority.snapshot_for(1)
	_check(final.run_stage == CoopRunState.VICTORY and final.run_revision == 9 and final.encounter_id == 3
		and not final.has("reward_options"), "single-enemy boss victory ends the authoritative run")


func _authority_play(authority: Authority, peer: int, sequence: int, target: String) -> void:
	var view := authority.snapshot_for(peer)
	_check(authority.submit(peer, _play_request(view, sequence, target)) == Authority.Result.ACCEPTED,
		"the host accepts targeted card command %d" % sequence)


func _play_request(view: Dictionary, sequence: int, target: String) -> Dictionary:
	var copy := -1
	for card in view.hand:
		if card.id == "basic_strike":
			copy = card.copy
			break
	return {"actor": view.viewer, "sequence": sequence, "kind": int(Authority.Command.PLAY_CARD), "copy": copy,
		"target": target, "round": view.round, "phase": view.phase, "ready_epoch": view.ready_epoch, "encounter_id": view.encounter_id}


func _reward(view: Dictionary, sequence: int, card: String) -> Dictionary:
	return {"actor": view.viewer, "sequence": sequence, "encounter_id": view.encounter_id,
		"kind": int(Authority.Command.REWARD), "reward_id": card}


func _authority_fixture() -> RunData:
	var data: RunData = ROUTE.duplicate()
	data.opening_encounters = [_one_hp(data.opening_encounters[0])]
	data.intermediate_encounters = [_one_hp(data.intermediate_encounters[0])]
	data.boss_encounter = _one_hp(data.boss_encounter)
	data.starting_deck = [STRIKE, STRIKE, STRIKE, STRIKE, STRIKE]
	var universal: CardData = STRIKE.duplicate()
	universal.id = &"test_universal"
	universal.owner_class_id = &"universal"
	data.reward_candidates = data.reward_candidates.duplicate()
	data.reward_candidates.append(universal)
	return data


func _one_hp(template: EncounterData) -> EncounterData:
	var encounter: EncounterData = template.duplicate()
	encounter.enemy_max_hp = 1
	encounter.enemies = template.enemies.duplicate()
	for index in encounter.enemies.size():
		encounter.enemies[index] = template.enemies[index].duplicate()
		encounter.enemies[index].max_hp = 1
	return encounter


func _win(combat: CombatState, player: StringName) -> void:
	for enemy in combat.enemies:
		enemy.hp = 1
		var copy := _strike_copy(combat, player)
		if copy < 0:
			# Keep transition tests independent of the opening draw. Other tests cover actual shuffle/replay.
			var state := combat.players[player]
			for drawn_copy in state.draw_pile:
				if combat.card_data(drawn_copy).id == STRIKE.id:
					copy = drawn_copy
					break
			if copy >= 0:
				state.draw_pile.erase(copy)
				state.hand.append(copy)
		_check(combat.play_card(player, copy, enemy.id), "finish enemy %s" % enemy.id)
	_check(combat.phase == CombatState.Phase.VICTORY, "the resolver reaches victory after the final enemy")


func _strike_copy(combat: CombatState, player: StringName) -> int:
	for copy in combat.players[player].hand:
		if combat.card_data(copy).id == STRIKE.id:
			return copy
	return -1


func _fresh(combat: CombatState, player_id: StringName, hp: int, cards: int) -> bool:
	var player := combat.players[player_id]
	return (combat.round_number == 1 and combat.phase == CombatState.Phase.PLAYER and combat.action_history.is_empty()
		and player.hp == hp and player.hand.size() == 5 and player.draw_pile.size() == cards - 5
		and player.discard_pile.is_empty() and player.mana == 3 and player.block == 0 and player.strength == 0
		and player.dexterity == 0 and player.poison == 0 and player.burning == 0 and player.next_attack_bonus == 0
		and not player.ended_turn and not player.recovered_after_victory and player.ready_epoch == 0)


func _ids(combat: CombatState) -> Array[StringName]:
	var ids: Array[StringName] = []
	for enemy in combat.enemies:
		ids.append(enemy.id)
	return ids


func _check(condition: bool, context: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(context)
