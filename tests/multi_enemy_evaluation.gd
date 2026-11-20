extends SceneTree

const CardEffect = preload("res://scripts/combat/card_effect.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const EnemyAction = preload("res://scripts/combat/enemy_action.gd")
const EnemyState = preload("res://scripts/combat/enemy_state.gd")
const SEATS: Array[StringName] = [&"Battle Mage 1", &"Battle Mage 2", &"Battle Mage 3", &"Battle Mage 4"]
const SEEDS: Array[int] = [104774, 42017, 918273, 20261119, 771293]
const ENCOUNTERS: Array[EncounterData] = [
	preload("res://resources/prototype/enemies/slime.tres"),
	preload("res://resources/prototype/enemies/two_slimes.tres"),
	preload("res://resources/prototype/enemies/goblin_treant.tres"),
	preload("res://resources/prototype/enemies/three_enemies.tres"),
]

# Comparing the first two isolates defensive priority. Comparing the latter two isolates target priority.
const POLICIES := ["focus-threat", "cover-and-focus", "cover-and-spread"]

var _checks := 0
var _failures := 0


func _initialize() -> void:
	var samples := 0
	for encounter in ENCOUNTERS:
		for size in range(1, SEATS.size() + 1):
			for seed in SEEDS:
				for policy in POLICIES:
					var roster: Array[StringName] = SEATS.slice(0, size)
					var metric := _sample(encounter, roster, seed, policy)
					_check(metric == _sample(encounter, roster, seed, policy), "matched inputs replay the same trace")
					print("MULTI_ENEMY_METRIC ", JSON.stringify(metric))
					samples += 1
	print("Multi-enemy evaluation: %d samples, %d checks, %d failures." % [samples, _checks, _failures])
	quit(int(_failures > 0))


func _sample(encounter: EncounterData, roster: Array[StringName], seed: int, policy: String) -> Dictionary:
	var combat := CombatState.new(encounter, seed, roster)
	var seats := {}
	for player_id in roster:
		seats[player_id] = {"start_hp": combat.players[player_id].hp, "cards": 0, "offensive_cards": 0,
			"ends": 0, "used_rounds": 0, "eligible_rounds": 0, "hp_lost": 0}
	var enemies := {}
	for enemy in combat.enemies:
		enemies[enemy.id] = {"name": enemy.display_name, "max_hp": enemy.max_hp, "targeted": 0,
			"targeted_with_choice": 0, "card_hp_damage": 0, "block_absorbed": 0, "final_hp": 0, "actions": 0}
	var actions: Array[Dictionary] = []
	var first_card_elimination := &""
	var target_choices := 0
	while combat.phase == CombatState.Phase.PLAYER and combat.round_number <= 40:
		var round_number := combat.round_number
		var start := (seed + round_number - 1) % roster.size()
		for offset in roster.size():
			var player_id := roster[(start + offset) % roster.size()]
			if not combat.can_end_turn(player_id):
				continue
			var seat: Dictionary = seats[player_id]
			var prior_cards: int = seat.cards
			seat.eligible_rounds += 1
			while combat.can_end_turn(player_id):
				var target := _target(combat, policy == "cover-and-spread")
				var copy_id := _choose_card(combat, player_id, target.id, policy != "focus-threat")
				if copy_id < 0:
					break
				var offensive := combat.card_data(copy_id).targets_enemy()
				var living := 0
				for enemy in combat.enemies:
					living += int(enemy.is_alive())
				var prior_hp := target.hp
				var prior_block := target.block
				if not combat.play_card(player_id, copy_id, target.id if offensive else &""):
					_check(false, "a selected legal card was rejected")
					break
				seat.cards += 1
				if offensive:
					seat.offensive_cards += 1
					var metric: Dictionary = enemies[target.id]
					metric.targeted += 1
					metric.targeted_with_choice += int(living > 1)
					metric.card_hp_damage += prior_hp - target.hp
					metric.block_absorbed += prior_block - target.block
					target_choices += int(living > 1)
					if first_card_elimination.is_empty() and not target.is_alive():
						first_card_elimination = target.id
			seat.used_rounds += int(seat.cards > prior_cards)
			if combat.can_end_turn(player_id):
				_end_turn(combat, player_id, actions)
				seat.ends += 1
			if combat.phase != CombatState.Phase.PLAYER or combat.round_number != round_number:
				break
	var accepted := 0
	var hits := 0
	for player_id in roster:
		var player := combat.players[player_id]
		var metric: Dictionary = seats[player_id]
		metric.hp_lost = metric.start_hp - (0 if player.recovered_after_victory else player.hp)
		metric["final_hp"] = player.hp
		metric["recovered"] = player.recovered_after_victory
		accepted += metric.cards + metric.ends
		hits += metric.offensive_cards
	var targeted := 0
	var acted := 0
	var living := 0
	for enemy in combat.enemies:
		var metric: Dictionary = enemies[enemy.id]
		metric.final_hp = enemy.hp
		metric.actions = enemy.action_index
		targeted += metric.targeted
		acted += metric.actions
		living += int(enemy.is_alive())
	_check(accepted == combat.action_history.size() and hits == targeted and acted == actions.size(),
		"each accepted command, targeted card and executed intent is accounted for")
	_check((combat.phase == CombatState.Phase.VICTORY and living == 0)
		or (combat.phase == CombatState.Phase.DEFEAT and living > 0), "the encounter reaches a consistent outcome")
	return {"fixture": String(encounter.enemy_id), "party": roster.size(), "seed": seed, "policy": policy,
		"outcome": CombatState.Phase.keys()[combat.phase], "rounds": combat.round_number,
		"actions": actions, "enemies": enemies, "seats": seats, "multiple_target_plays": target_choices,
		"first_card_elimination": String(first_card_elimination),
		"status_hp_loss": _status_hp_loss(combat.combat_log),
		"trace": JSON.stringify([combat.action_history, combat.combat_log]).sha256_text()}


func _target(combat: CombatState, spread: bool) -> EnemyState:
	var selected: EnemyState
	var best_threat := -1
	var best_tiebreak := 0
	for enemy in combat.enemies:
		if not enemy.is_alive():
			continue
		var intent := enemy.intent()
		# Focus the largest imminent hit, with an easier elimination breaking ties.
		var threat := int(intent.amount) if not spread and intent.kind == EnemyAction.Kind.ATTACK else 0
		var tiebreak := enemy.hp if spread else -(enemy.hp + enemy.block)
		if threat > best_threat or (threat == best_threat and tiebreak > best_tiebreak):
			selected = enemy
			best_threat = threat
			best_tiebreak = tiebreak
	return selected


func _choose_card(combat: CombatState, player_id: StringName, target: StringName, cover: bool) -> int:
	var player := combat.players[player_id]
	var incoming := 0
	for enemy in combat.enemies:
		if enemy.is_alive() and enemy.intent().kind == EnemyAction.Kind.ATTACK:
			incoming += int(enemy.intent().amount)
	var first_legal := -1
	var first_attack := -1
	for copy_id in player.hand:
		var card := combat.card_data(copy_id)
		if not combat.can_play_card(player_id, copy_id, target if card.targets_enemy() else &""):
			continue
		if first_legal < 0:
			first_legal = copy_id
		if card.is_attack and first_attack < 0:
			first_attack = copy_id
		if cover and player.block < incoming:
			for effect in card.effects:
				if effect.kind == CardEffect.Kind.GAIN_BLOCK:
					return copy_id
	return first_attack if first_attack >= 0 else first_legal


func _end_turn(combat: CombatState, player_id: StringName, actions: Array[Dictionary]) -> void:
	var expected := {}
	for enemy in combat.enemies:
		if enemy.is_alive():
			expected[enemy.id] = {"index": enemy.action_index, "intent": enemy.intent(), "round": combat.round_number}
	_check(combat.end_turn(player_id), "an eligible seat's End Turn is accepted")
	for enemy in combat.enemies:
		if expected.has(enemy.id) and enemy.action_index > expected[enemy.id].index:
			var act: Dictionary = expected[enemy.id]
			actions.append({"id": String(enemy.id), "round": act.round,
				"kind": EnemyAction.Kind.keys()[act.intent.kind], "amount": act.intent.amount})


func _status_hp_loss(log_messages: PackedStringArray) -> Dictionary:
	var totals := {"poison": 0, "burning": 0}
	for message in log_messages:
		if message.ends_with(" HP to Poison."):
			totals.poison += message.get_slice(" lost ", 1).get_slice(" ", 0).to_int()
		elif message.ends_with(" HP to Burning."):
			totals.burning += message.get_slice(" lost ", 1).get_slice(" ", 0).to_int()
	return totals


func _check(condition: bool, context: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr(context)
