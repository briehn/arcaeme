extends SceneTree

const CardData = preload("res://scripts/combat/card_data.gd")
const CardEffect = preload("res://scripts/combat/card_effect.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const CoopRunState = preload("res://scripts/run/coop_run_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const PacingExperiment = preload("res://scripts/run/pacing_experiment.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const RunState = preload("res://scripts/run/run_state.gd")
const ROUTE = preload("res://resources/prototype/enemy_variety_run.tres")
const ORIGINAL = preload("res://resources/prototype/battle_mage_run.tres")
const SLIME = preload("res://resources/prototype/enemies/slime.tres")
const SEATS: Array[StringName] = [&"Battle Mage 1", &"Battle Mage 2", &"Battle Mage 3", &"Battle Mage 4"]
const SEEDS: Array[int] = [104775, 42017, 918273, 20261119, 771293]
const DEFINING_DAMAGE := {
	&"goblin": 14, &"treant": 10, &"slime": 6, &"strengthening_goblin": 14, &"defensive_treant": 10,
}
const RUN_VARIANTS := [
	PacingExperiment.VariantKind.BASELINE,
	PacingExperiment.VariantKind.TIMING,
	PacingExperiment.VariantKind.DURABILITY,
]

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_check(ROUTE.starting_deck == ORIGINAL.starting_deck and ROUTE.reward_candidates == ORIGINAL.reward_candidates
		and ROUTE.run_seed == ORIGINAL.run_seed and ROUTE.player_max_hp == ORIGINAL.player_max_hp,
		"the reference route preserves the existing starter deck, reward pool, seed and Mage HP")
	var options := OS.get_cmdline_user_args()
	var variants: Array[PacingExperiment.VariantKind] = []
	variants.assign(RUN_VARIANTS)
	if "--combined" in options:
		variants.append(PacingExperiment.VariantKind.COMBINED)
	var compare_rewards := "--compare-rewards" in options
	for seed_index in SEEDS.size():
		var template: RunData = ROUTE.duplicate()
		template.run_seed = SEEDS[seed_index]
		var slime: RunData = template.duplicate()
		slime.opening_encounters = [SLIME]
		for size in range(1, 5):
			for variant in variants:
				var data := PacingExperiment.make_run(template, variant, size)
				var label: String = PacingExperiment.VariantKind.keys()[variant].to_lower()
				_check(data.run_seed == template.run_seed and data.player_max_hp == template.player_max_hp
					and data.starting_deck == template.starting_deck and data.reward_candidates == template.reward_candidates,
					"the pacing fixture preserves the seed, Mage HP, starting deck and reward pool")
				_measure(data, label, size, seed_index, true, compare_rewards)
			_measure(slime, "slime", size, seed_index, false)
	print("Enemy variety evaluation: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _measure(data: RunData, label: String, size: int, seed_index: int,
		play_final := true, compare_rewards := false) -> void:
	for cover_intent in [false, true]:
		# Solo has one legal seat order. In parties the alternative rotates the starting seat
		# between rounds and varies the round-one choice by seed for matched sensitivity tests.
		for order_offset in ([-1] if size == 1 else [-1, seed_index]):
			for take_reward in ([true, false] if compare_rewards else [true]):
				var result := _evaluate(data, label, size, cover_intent, order_offset, play_final, take_reward)
				_check(result == _evaluate(data, label, size, cover_intent, order_offset, play_final, take_reward),
					"the same seed, policy, seat order, route and rewards replay exactly")
				print("METRIC ", JSON.stringify(result))


func _evaluate(data: RunData, label: String, size: int, cover_intent: bool, order_offset: int,
		play_final: bool, take_reward: bool) -> Dictionary:
	var result := (_solo(data, cover_intent, play_final, take_reward) if size == 1
		else _coop(data, size, cover_intent, order_offset, play_final, take_reward))
	result.merge({"variant": label, "seed": data.run_seed, "party": size,
		"policy": "cover-intent" if cover_intent else "attack-first",
		"order": "fixed" if order_offset < 0 else "rotating", "order_offset": order_offset,
		"reward_policy": ("shieldstrike" if take_reward else "all-skip") if play_final else "not-applicable"})
	return result


func _solo(data: RunData, cover_intent: bool, play_final: bool, take_reward: bool) -> Dictionary:
	var run := RunState.new(data)
	_check(run.choose_opening(data.opening_encounters[0].enemy_id), "solo chooses its opening")
	var fights: Array[Dictionary] = [_fight(run.active_combat, run.active_encounter, cover_intent, -1)]
	_check(run.finish_combat(run.active_combat), "solo settles its opening")
	var reward_decisions := 0
	var rewards_taken := 0
	if play_final and run.stage == RunState.Stage.REWARD:
		var selected := run.take_reward(&"shieldstrike") if take_reward else run.skip_reward()
		_check(selected and run.start_boss(), "solo selects or skips a reward and starts the final encounter")
		if run.stage == RunState.Stage.BOSS_COMBAT:
			reward_decisions = 1
			rewards_taken = int(take_reward)
			var reward_copy := data.starting_deck.size() if take_reward else -1
			fights.append(_fight(run.active_combat, run.active_encounter, cover_intent, -1, reward_copy))
			_check(run.finish_combat(run.active_combat), "solo settles the final encounter")
	return _summarize(fights, play_final, reward_decisions, rewards_taken)


func _coop(data: RunData, size: int, cover_intent: bool, order_offset: int,
		play_final: bool, take_reward: bool) -> Dictionary:
	var players: Array[StringName] = SEATS.slice(0, size)
	var run := CoopRunState.new(data, players)
	var fights: Array[Dictionary] = [_fight(run.active_combat, run.active_encounter, cover_intent, order_offset)]
	run.observe_combat_result()
	var reward_decisions := 0
	var rewards_taken := 0
	if play_final and run.stage == CoopRunState.REWARD:
		for player_id in players:
			var pick := &"shieldstrike" if take_reward and player_id == players[0] else &""
			var accepted := run.submit_reward(player_id, pick)
			_check(accepted, "each seat can make its private reward decision")
			if accepted:
				reward_decisions += 1
				rewards_taken += int(not pick.is_empty())
		_check(run.stage == CoopRunState.BOSS, "the final encounter begins after all reward decisions")
		if run.stage == CoopRunState.BOSS:
			var reward_copy := data.starting_deck.size() if take_reward else -1
			fights.append(_fight(run.active_combat, run.active_encounter, cover_intent, order_offset, reward_copy))
			run.observe_combat_result()
	return _summarize(fights, play_final, reward_decisions, rewards_taken)


func _summarize(fights: Array[Dictionary], play_final: bool, decisions: int, taken: int) -> Dictionary:
	var last := fights.back() as Dictionary
	var outcome: String = last.outcome
	_check(not play_final or outcome != "VICTORY" or fights.size() == 2,
		"a successful two-fight run visits both encounters")
	var total_rounds := 0
	var total_actions := 0
	var total_meaningful := 0
	var total_hp_lost := 0
	var reward_drawn := false
	var reward_plays := 0
	for fight in fights:
		total_rounds += int(fight.rounds)
		total_actions += int(fight.accepted_actions)
		for seat in fight.seats:
			total_meaningful += int(seat.meaningful_plays)
			total_hp_lost += int(seat.hp_lost)
			reward_drawn = reward_drawn or seat.reward_drawn
			reward_plays += int(seat.reward_plays)
	return {"fights": fights, "outcome": outcome, "visited_final": fights.size() == 2, "rounds": total_rounds,
		"accepted_actions": total_actions, "meaningful_plays": total_meaningful, "hp_lost": total_hp_lost,
		"reward_decisions": decisions, "rewards_taken": taken, "rewards_skipped": decisions - taken,
		"reward_drawn": reward_drawn, "reward_plays": reward_plays}


func _fight(combat: CombatState, encounter: EncounterData, cover_intent: bool, order_offset: int,
		reward_copy := -1) -> Dictionary:
	var roster := combat.players.keys()
	var seats: Array[Dictionary] = []
	for player: CombatState.PlayerState in combat.players.values():
		seats.append({"player": String(player.id), "start_hp": player.hp, "slots": 0, "empty_slots": 0,
			"card_plays": 0, "meaningful_plays": 0, "attack_plays": 0, "end_turns": 0, "damage": 0,
			"reward_copy": reward_copy if seats.is_empty() else -1, "reward_drawn": false, "reward_plays": 0})
	var intents: Array[int] = []
	while combat.phase == CombatState.Phase.PLAYER and combat.round_number <= 40:
		var round_start := combat.round_number
		intents.append(combat.enemy_attack_damage())
		for index in roster.size():
			_record_reward_draw(combat.players[roster[index]], seats[index])
		var starting_seat := 0 if order_offset < 0 else (order_offset + round_start - 1) % roster.size()
		for offset in roster.size():
			var index := (starting_seat + offset) % roster.size()
			var seat := seats[index]
			var player_id: StringName = roster[index]
			if combat.can_end_turn(player_id):
				_play_slot(combat, player_id, encounter.enemy_id, cover_intent, seat)
			if combat.round_number != round_start or combat.phase != CombatState.Phase.PLAYER:
				break
	_check(combat.phase in [CombatState.Phase.VICTORY, CombatState.Phase.DEFEAT], "fight settles within test limit")
	var attacks: Array[int] = []
	var prefix := "%s attacks for " % encounter.enemy_name
	for line in combat.combat_log:
		if line.begins_with(prefix):
			attacks.append(line.trim_prefix(prefix).get_slice(" ", 0).to_int())
	for index in roster.size():
		var player := combat.players[roster[index]]
		var seat := seats[index]
		# These fixtures have no combat healing. Victory recovery returns a downed seat from zero HP.
		seat["hp_lost"] = seat.start_hp - (0 if player.recovered_after_victory else player.hp)
		seat["end_hp"] = player.hp
		seat["defeated"] = player.hp == 0 or player.recovered_after_victory
		seat["recovered"] = player.recovered_after_victory
		seat.erase("reward_copy")
	var defining_damage: int = DEFINING_DAMAGE[encounter.enemy_id]
	var accepted_cards := 0
	var accepted_ends := 0
	for seat in seats:
		accepted_cards += int(seat.card_plays)
		accepted_ends += int(seat.end_turns)
	_check(accepted_cards + accepted_ends == combat.action_history.size(), "every accepted action enters exactly one metric bucket")
	return {"enemy": String(encounter.enemy_name), "enemy_id": String(encounter.enemy_id),
		"enemy_max_hp": encounter.enemy_max_hp, "combat_seed": combat.shuffle_seed,
		"outcome": CombatState.Phase.keys()[combat.phase], "rounds": combat.round_number,
		"accepted_actions": combat.action_history.size(), "card_plays": accepted_cards, "end_turn_actions": accepted_ends,
		"attacks": attacks, "intents": intents, "killed_before_attack": attacks.is_empty() and combat.enemy_hp == 0,
		"defining_damage": defining_damage, "first_defining_round": attacks.find(defining_damage) + 1,
		"first_defining_intent_round": intents.find(defining_damage) + 1,
		"seats": seats, "trace": JSON.stringify([combat.action_history, combat.combat_log]).sha256_text()}


func _play_slot(combat: CombatState, player_id: StringName, enemy_id: StringName, cover_intent: bool,
		seat: Dictionary) -> void:
	seat.slots += 1
	var previous_plays: int = seat.meaningful_plays
	while true:
		var copy := _choose_card(combat, player_id, enemy_id, cover_intent)
		if copy < 0:
			break
		var card := combat.card_data(copy)
		var target := enemy_id if card.targets_enemy() else &""
		var previous_hp := combat.enemy_hp
		if not combat.play_card(player_id, copy, target):
			_check(false, "a selected card remains legal")
			break
		seat.card_plays += 1
		seat.meaningful_plays += int(_is_meaningful(card))
		seat.attack_plays += int(card.is_attack)
		seat.damage += previous_hp - combat.enemy_hp
		seat.reward_plays += int(copy == seat.reward_copy)
		_record_reward_draw(combat.players[player_id], seat)
	if seat.meaningful_plays == previous_plays:
		seat.empty_slots += 1
	if combat.can_end_turn(player_id):
		if combat.end_turn(player_id):
			seat.end_turns += 1
		else:
			_check(false, "an available End Turn is accepted")


func _record_reward_draw(player: CombatState.PlayerState, seat: Dictionary) -> void:
	if seat.reward_copy >= 0 and seat.reward_copy in player.hand:
		seat.reward_drawn = true


func _is_meaningful(card: CardData) -> bool:
	if card.is_attack:
		return true
	for effect in card.effects:
		if effect.amount > 0 and effect.kind in [CardEffect.Kind.GAIN_BLOCK, CardEffect.Kind.PREPARE_ATTACK]:
			return true
	return false


func _choose_card(combat: CombatState, player_id: StringName, enemy_id: StringName, cover_intent: bool) -> int:
	var player := combat.players[player_id]
	var needs_block := cover_intent and player.block < combat.enemy_attack_damage()
	var first_available := -1
	var first_attack := -1
	for copy_id in player.hand:
		var card := combat.card_data(copy_id)
		var target := enemy_id if card.targets_enemy() else &""
		if not combat.can_play_card(player_id, copy_id, target):
			continue
		if first_available < 0:
			first_available = copy_id
		if card.is_attack and first_attack < 0:
			first_attack = copy_id
		if needs_block:
			for effect in card.effects:
				if effect.kind == CardEffect.Kind.GAIN_BLOCK:
					return copy_id
	return first_attack if first_attack >= 0 else first_available


func _check(condition: bool, context: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr(context)
