extends "res://tests/enemy_variety_evaluation.gd"

const GOBLIN = preload("res://resources/prototype/enemies/goblin.tres")
const TREANT = preload("res://resources/prototype/enemies/treant.tres")
const STRENGTHENING = preload("res://resources/prototype/enemies/strengthening_goblin.tres")
const DEFENSIVE = preload("res://resources/prototype/enemies/defensive_treant.tres")
const ENCOUNTERS: Array[EncounterData] = [GOBLIN, STRENGTHENING, TREANT, DEFENSIVE]


func _initialize() -> void:
	for baseline in [GOBLIN, TREANT]:
		var variant := STRENGTHENING if baseline == GOBLIN else DEFENSIVE
		_check(baseline.enemy_max_hp == variant.enemy_max_hp and baseline.player_max_hp == variant.player_max_hp
			and baseline.test_deck == variant.test_deck, "the comparison keeps HP and the player deck constant")
	for encounter in ENCOUNTERS:
		for size in range(1, 5):
			var roster: Array[StringName] = SEATS.slice(0, size)
			for seed in SEEDS:
				for cover_intent in [false, true]:
					var result := _sample(encounter, roster, seed, cover_intent)
					_check(result == _sample(encounter, roster, seed, cover_intent),
						"the same fixture, roster, seed, and policy replay the same trace")
					print("ACTION_METRIC ", JSON.stringify(result))
	print("Enemy action evaluation: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _sample(encounter: EncounterData, roster: Array[StringName], seed: int, cover_intent: bool) -> Dictionary:
	var combat := CombatState.new(encounter, seed, roster)
	var result := _fight(combat, encounter, cover_intent, -1)
	result.merge(_enemy_action_totals(encounter, combat))
	result.merge({"party": roster.size(), "seed": seed, "policy": "cover-intent" if cover_intent else "attack-first"})
	return result


func _enemy_action_totals(encounter: EncounterData, combat: CombatState) -> Dictionary:
	var block_gained := 0
	var block_absorbed := 0
	var block_expired := 0
	var strength := encounter.enemy_starting_strength
	var strength_gained := 0
	var attack_bonuses: Array[int] = []
	for line in combat.combat_log:
		if not line.begins_with(encounter.enemy_name + " "):
			continue
		var event := line.trim_prefix(encounter.enemy_name + " ")
		var amount := event.get_slice(" ", 1).to_int()
		if event.begins_with("gained ") and event.ends_with(" Block."):
			block_gained += amount
		elif event.begins_with("blocked "):
			block_absorbed += amount
		elif event.ends_with(" remaining Block at action start."):
			block_expired += amount
		elif event.begins_with("gained ") and event.ends_with(" Strength."):
			strength_gained += amount
			strength += amount
		elif event.begins_with("attacks for "):
			attack_bonuses.append(strength)
	_check(block_gained == block_absorbed + block_expired + combat.enemy_block, "every granted Block point is accounted for")
	_check(strength == combat.enemy_strength, "Strength grants match the final state")
	return {"block_gained": block_gained, "block_absorbed": block_absorbed, "block_expired": block_expired,
		"block_remaining": combat.enemy_block, "strength_gained": strength_gained,
		"strength_per_executed_attack": attack_bonuses}
