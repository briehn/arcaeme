extends "res://tests/multi_enemy_evaluation.gd"

const CoopRunState = preload("res://scripts/run/coop_run_state.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const RunState = preload("res://scripts/run/run_state.gd")
const ROUTE = preload("res://resources/prototype/multi_enemy_run.tres")


func _initialize() -> void:
	var samples := 0
	for size in range(1, SEATS.size() + 1):
		var roster := SEATS.slice(0, size)
		if size == 1:
			roster[0] = RunState.PLAYER_ID
		for policy in POLICIES:
			var group: Array[Dictionary] = []
			for seed_index in SEEDS.size():
				var seed: int = SEEDS[seed_index]
				var result := _run_sample(roster, seed, seed_index, policy)
				_check(result == _run_sample(roster, seed, seed_index, policy), "identical inputs replay the full run and metrics")
				print("MULTI_ENEMY_RUN_METRIC ", JSON.stringify(result))
				group.append(result)
				samples += 1
			print("MULTI_ENEMY_RUN_SUMMARY ", JSON.stringify(_summarize(size, policy, group)))
	print("Multi-enemy run evaluation: %d samples, %d checks, %d failures." % [samples, _checks, _failures])
	quit(int(_failures > 0))


func _run_sample(roster: Array[StringName], seed: int, seed_index: int, policy: String,
		template: RunData = ROUTE) -> Dictionary:
	var data: RunData = template.duplicate()
	data.run_seed = seed
	var solo: RunState
	var party: CoopRunState
	if roster.size() == 1:
		solo = RunState.new(data)
		_check(solo.choose_opening(data.opening_encounters[0].enemy_id), "solo enters the configured opening")
	else:
		party = CoopRunState.new(data, roster)
	var result := {"seed": seed, "party": roster.size(), "policy": policy, "encounters": [], "rewards": {},
		"victory": false, "final_stage": "", "final_decks": {}, "final_hp": {}}
	for player in roster:
		result.rewards[player] = []
	for encounter_id in range(1, data.encounter_count() + 1):
		var combat := solo.active_combat if solo != null else party.active_combat
		var actual_id := solo.encounter_id if solo != null else party.encounter_id
		var definition := solo.active_encounter if solo != null else party.active_encounter
		_check(actual_id == encounter_id, "run visits every encounter in order")
		var metrics := _measure_combat(combat, roster, seed, policy, data.starting_deck.size(), result.rewards)
		metrics["encounter_id"] = encounter_id
		metrics["name"] = definition.enemy_name
		result.encounters.append(metrics)
		var won := combat.phase == CombatState.Phase.VICTORY
		if solo != null:
			_check(solo.finish_combat(combat), "solo accepts the finished encounter")
		else:
			party.observe_combat_result()
		if not won or encounter_id == data.encounter_count():
			result.victory = won
			result.final_stage = RunState.Stage.keys()[solo.stage].to_lower() if solo != null else party.stage
			for player in roster:
				result.final_hp[player] = combat.players[player].hp
			break
		for seat in roster.size():
			var player := roster[seat]
			var offers := data.reward_offers(RunData.BATTLE_MAGE, encounter_id, seat)
			var reward_id := _draft_reward(offers, seed, seed_index, seat, encounter_id)
			var accepted: bool
			if solo != null:
				accepted = solo.take_reward(reward_id) if reward_id != &"" else solo.skip_reward()
			else:
				accepted = party.submit_reward(player, reward_id)
			_check(accepted, "each seat independently settles this reward")
			result.rewards[player].append({"after_encounter": encounter_id, "card": String(reward_id)})
		if solo != null:
			_check(solo.start_next_encounter(), "the settled solo reward unlocks the next encounter")
	for player in roster:
		var deck := solo.deck_cards() if solo != null else party.deck_cards(player)
		var deck_ids := PackedStringArray()
		for card in deck:
			deck_ids.append(String(card.id))
		result.final_decks[player] = deck_ids
		var expected := data.starting_deck.size()
		for reward: Dictionary in result.rewards[player]:
			expected += int(not reward.card.is_empty())
		_check(deck.size() == expected, "each deck change is accounted for")
	_check((result.victory and result.final_stage == "victory" and result.encounters.size() == data.encounter_count())
		or (not result.victory and result.final_stage == "defeat"), "run outcome agrees with the final encounter")
	return result


func _draft_reward(offers: Array, seed: int, seed_index: int, seat: int, encounter_id: int) -> StringName:
	if (seed_index + seat + encounter_id) % 2 != 0:
		return &""
	return offers[(seed + seat + encounter_id) % offers.size()].id


func _measure_combat(combat: CombatState, roster: Array[StringName], seed: int, policy: String,
		starting_deck_size: int, rewards: Dictionary) -> Dictionary:
	var players := {}
	for player in roster:
		players[player] = {"starting_hp": combat.players[player].hp, "cards": 0, "reward_cards": {}}
	var enemy_actions: Array[Dictionary] = []
	var targeted_with_choice := {}
	while combat.phase == CombatState.Phase.PLAYER and combat.round_number <= 40:
		var round_number := combat.round_number
		var start := (seed + round_number - 1) % roster.size()
		for offset in roster.size():
			var player := roster[(start + offset) % roster.size()]
			while combat.can_end_turn(player):
				var enemy := _target(combat, policy == "cover-and-spread")
				var copy := _choose_card(combat, player, enemy.id, policy != "focus-threat")
				if copy < 0:
					break
				var target := enemy.id if combat.card_data(copy).targets_enemy() else &""
				var living_before := 0
				if not target.is_empty():
					for candidate in combat.enemies:
						living_before += int(candidate.is_alive())
				if not combat.play_card(player, copy, target):
					_check(false, "a legal scripted card was rejected")
					break
				if not target.is_empty() and living_before > 1:
					targeted_with_choice[target] = targeted_with_choice.get(target, 0) + 1
			if combat.can_end_turn(player):
				_end_turn(combat, player, enemy_actions)
			if combat.phase != CombatState.Phase.PLAYER or combat.round_number != round_number:
				break
	var targeted := {}
	var first_target := ""
	for enemy in combat.enemies:
		targeted[String(enemy.id)] = 0
	for command in combat.action_history:
		if command[&"command"] != &"play_card":
			continue
		var player_id: StringName = command[&"player"]
		var metric: Dictionary = players[player_id]
		metric.cards += 1
		var target := String(command[&"target"])
		if not target.is_empty():
			targeted[target] += 1
			if first_target.is_empty():
				first_target = target
		var local_copy: int = command[&"copy"] - combat.players[player_id].first_copy_id
		_count_reward_card(metric.reward_cards, local_copy - starting_deck_size, rewards[player_id])
	var zero_card_seats := 0
	var party_hp_lost := 0
	for player in roster:
		var metric: Dictionary = players[player]
		var state := combat.players[player]
		metric["final_hp"] = state.hp
		metric["recovered"] = state.recovered_after_victory
		metric["hp_lost"] = metric.starting_hp - (0 if state.recovered_after_victory else state.hp)
		party_hp_lost += metric.hp_lost
		zero_card_seats += int(metric.cards == 0)
	var attacks := 0
	for action in enemy_actions:
		attacks += int(action.kind == "ATTACK")
	var actual_actions := 0
	for enemy in combat.enemies:
		actual_actions += enemy.action_index
	_check(actual_actions == enemy_actions.size(), "record actions that executed through the real enemy phase")
	_check(combat.phase in [CombatState.Phase.VICTORY, CombatState.Phase.DEFEAT], "each fight reaches a terminal result")
	return {"outcome": CombatState.Phase.keys()[combat.phase], "rounds": combat.round_number,
		"commands": combat.action_history.size(), "enemy_attacks": attacks, "enemy_actions": enemy_actions,
		"targeted": targeted, "targeted_with_choice": targeted_with_choice, "first_target": first_target, "players": players,
		"zero_card_seats": zero_card_seats, "party_hp_lost": party_hp_lost,
		"status_hp_loss": _status_hp_loss(combat.combat_log),
		"trace": JSON.stringify([combat.action_history, combat.combat_log]).sha256_text()}


func _count_reward_card(uses: Dictionary, reward_index: int, rewards: Array) -> void:
	if reward_index < 0:
		return
	for reward: Dictionary in rewards:
		if reward.card.is_empty():
			continue
		if reward_index == 0:
			var key := "%d:%s" % [reward.after_encounter, reward.card]
			uses[key] = uses.get(key, 0) + 1
			return
		reward_index -= 1
	_check(false, "an appended deck copy traces back to this seat's reward")


func _summarize(size: int, policy: String, group: Array[Dictionary]) -> Dictionary:
	var encounters: Array[Dictionary] = []
	for _index in ROUTE.encounter_count():
		encounters.append({"reached": 0, "wins": 0, "rounds": 0, "commands": 0, "attacks": 0, "hp_lost": 0,
			"zero_card_seats": 0, "cards": 0, "reward_plays": 0, "targeted": {}, "targeted_with_choice": {}})
	var totals := {"party": size, "policy": policy, "cases": group.size(), "victories": 0,
		"takes": 0, "skips": 0, "reward_copies_used": 0, "fights": encounters}
	for result in group:
		var played_rewards := {}
		totals.victories += int(result.victory)
		for player in result.rewards:
			for reward: Dictionary in result.rewards[player]:
				totals.takes += int(not reward.card.is_empty())
				totals.skips += int(reward.card.is_empty())
		for fight: Dictionary in result.encounters:
			var total := encounters[fight.encounter_id - 1]
			total.reached += 1
			total.wins += int(fight.outcome == "VICTORY")
			total.rounds += fight.rounds
			total.commands += fight.commands
			total.attacks += fight.enemy_attacks
			total.hp_lost += fight.party_hp_lost
			total.zero_card_seats += fight.zero_card_seats
			for player_id in fight.players:
				var player: Dictionary = fight.players[player_id]
				total.cards += player.cards
				for reward in player.reward_cards:
					total.reward_plays += int(player.reward_cards[reward])
					played_rewards["%s:%s" % [player_id, reward]] = true
			for target in fight.targeted:
				total.targeted[target] = total.targeted.get(target, 0) + fight.targeted[target]
			for target in fight.targeted_with_choice:
				total.targeted_with_choice[target] = total.targeted_with_choice.get(target, 0) + fight.targeted_with_choice[target]
		totals.reward_copies_used += played_rewards.size()
	return totals
