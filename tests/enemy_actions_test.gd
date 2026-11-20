extends SceneTree

const CardData = preload("res://scripts/combat/card_data.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const EnemyAction = preload("res://scripts/combat/enemy_action.gd")
const Snapshot = preload("res://scripts/combat/combat_view_snapshot.gd")
const CoopRunState = preload("res://scripts/run/coop_run_state.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const GOBLIN = preload("res://resources/prototype/enemies/goblin.tres")
const TREANT = preload("res://resources/prototype/enemies/treant.tres")
const BUFF_GOBLIN = preload("res://resources/prototype/enemies/strengthening_goblin.tres")
const BLOCK_TREANT = preload("res://resources/prototype/enemies/defensive_treant.tres")
const RUN = preload("res://resources/prototype/enemy_variety_run.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const BLOCK = preload("res://resources/prototype/cards/basic_block.tres")
const PREP = preload("res://resources/prototype/cards/battle_preparation.tres")
const REVERSAL = preload("res://resources/prototype/cards/arcane_reversal.tres")
const SHIELDSTRIKE = preload("res://resources/prototype/cards/shieldstrike.tres")
const SALVO = preload("res://resources/prototype/cards/expansion/astral_salvo.tres")
const WARDED = preload("res://resources/prototype/cards/expansion/warded_strike.tres")
const HOST := &"Battle Mage 1"
const ALLY := &"Battle Mage 2"
const THIRD := &"Battle Mage 3"
const FOURTH := &"Battle Mage 4"
const SEED := 104774

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_default_compatibility()
	_test_block_timing()
	_test_per_hit_block_and_card_combinations()
	_test_periodic_damage()
	_test_strength_and_replay()
	_test_run_reset()
	print("Enemy actions: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _test_default_compatibility() -> void:
	_check(GOBLIN.action_cycle.is_empty() and TREANT.action_cycle.is_empty(),
		"the original enemy resources remain attack-only")
	var before := CombatState.new(GOBLIN, SEED, [HOST])
	_expect_intent(before, GOBLIN, EnemyAction.Kind.ATTACK, 7)
	_end(before, [HOST])
	_expect_intent(before, GOBLIN, EnemyAction.Kind.ATTACK, 14)
	_check(before.players[HOST].hp == 29 and before.enemy_block == 0 and before.enemy_strength == 0,
		"old attacks and Block-free state still use the legacy pattern")


func _test_block_timing() -> void:
	var data := _encounter(BLOCK_TREANT, [STRIKE])
	var combat := CombatState.new(data, SEED, [HOST, ALLY])
	_expect_intent(combat, data, EnemyAction.Kind.BLOCK, 8)
	_check(combat.end_turn(HOST) and combat.round_number == 1 and combat.enemy_block == 0 and combat.players[ALLY].hp == 36,
		"enemy cannot gain Block while another living player has an open turn")
	_expect_intent(combat, data, EnemyAction.Kind.BLOCK, 8)
	_end(combat, [ALLY])
	_check(combat.enemy_block == 8 and combat.players[HOST].hp == 36 and combat.players[ALLY].hp == 36,
		"Block action affects only the enemy and survives the next player-turn boundaries")
	_expect_intent(combat, data, EnemyAction.Kind.ATTACK, 4)
	_play(combat, data, STRIKE)
	_check(combat.enemy_hp == 55 and combat.enemy_block == 2, "one six-damage hit consumes six of eight enemy Block")
	_end(combat, [HOST])
	_check(combat.enemy_block == 2 and combat.round_number == 2, "the first ended Mage does not clear enemy Block")
	_end(combat, [ALLY])
	_check(combat.enemy_block == 0 and combat.players[HOST].hp == 32 and combat.players[ALLY].hp == 32
		and _before(combat.combat_log, "%s lost 2 remaining Block at action start." % data.enemy_name,
			"%s attacks for 4 damage." % data.enemy_name),
		"unconsumed Block expires at the enemy's next action-start before attacking")
	_expect_intent(combat, data, EnemyAction.Kind.ATTACK, 10)


func _test_per_hit_block_and_card_combinations() -> void:
	var data := _encounter(BLOCK_TREANT, [PREP, SALVO, WARDED, REVERSAL, SHIELDSTRIKE])
	data.enemy_starting_dexterity = 5
	var multi := CombatState.new(data, SEED, [HOST])
	_end(multi, [HOST])
	_check(multi.enemy_block == 8, "enemy action Block is fixed and receives no card-only Dexterity bonus")
	_play(multi, data, SALVO)
	_check(multi.enemy_hp == 49 and multi.enemy_block == 0 and multi.players[HOST].mana == 1
		and _before(multi.combat_log, "%s blocked 7 damage." % data.enemy_name, "%s blocked 1 damage." % data.enemy_name),
		"ordered seven-damage hits consume Block independently and only six damage gets through")

	var prepared := CombatState.new(data, SEED, [HOST])
	_end(prepared, [HOST])
	prepared.players[HOST].strength = 2
	_play(prepared, data, PREP)
	_play(prepared, data, SALVO)
	_check(prepared.enemy_hp == 42 and prepared.enemy_block == 0 and prepared.players[HOST].block == 7
		and prepared.players[HOST].next_attack_bonus == 0,
		"preparation and Strength change hit amounts before applying enemy Block to each hit")

	var reversal := CombatState.new(data, SEED, [HOST])
	_end(reversal, [HOST])
	reversal.players[HOST].dexterity = 2
	_play(reversal, data, WARDED)
	_check(reversal.enemy_block == 5 and reversal.players[HOST].block == 6,
		"Warded Strike hits the enemy's Block and still grants its independent Block")
	_play(reversal, data, REVERSAL)
	_check(reversal.enemy_hp == 46 and reversal.enemy_block == 0 and reversal.players[HOST].block == 0,
		"Reversal spends caster Block at its existing threshold before mitigation by enemy Block")

	var shield := CombatState.new(data, SEED, [HOST])
	_end(shield, [HOST])
	shield.players[HOST].block = 6
	_play(shield, data, SHIELDSTRIKE)
	_check(shield.enemy_hp == 53 and shield.enemy_block == 0 and shield.players[HOST].block == 6,
		"Shieldstrike reads and preserves caster Block while enemy Block absorbs separately")


func _test_periodic_damage() -> void:
	var data := _encounter(BLOCK_TREANT, [STRIKE])
	data.enemy_poison_per_attack = 3
	data.enemy_burning_per_attack = 5
	var combat := CombatState.new(data, SEED, [HOST])
	combat.enemy_poison = 4
	combat.enemy_burning = 5
	_end(combat, [HOST])
	var gain := "%s gained 8 Block." % data.enemy_name
	_check(combat.enemy_hp == 46 and combat.enemy_block == 8 and combat.enemy_poison == 3 and combat.enemy_burning == 3
		and _before(combat.combat_log, "%s lost 4 HP to Poison." % data.enemy_name, gain)
		and _before(combat.combat_log, gain, "%s lost 5 HP to Burning." % data.enemy_name),
		"Poison triggers before Block and Burning bypasses the new Block after the action")
	_check(combat.players[HOST].poison == 0 and combat.players[HOST].burning == 0 and combat.players[HOST].hp == 36,
		"the Block action does not trigger attack-only status payloads")
	combat.enemy_poison = 46
	_end(combat, [HOST])
	_check(combat.phase == CombatState.Phase.VICTORY and combat.enemy_block == 0 and combat.players[HOST].hp == 36
		and "%s attacks for 4 damage." % data.enemy_name not in combat.combat_log
		and _before(combat.combat_log, "%s lost 8 remaining Block at action start." % data.enemy_name,
			"%s lost 46 HP to Poison." % data.enemy_name),
		"Block expires before lethal Poison and the enemy never performs its announced action")

	var cancelled := CombatState.new(data, SEED, [HOST])
	cancelled.enemy_poison = 55
	_end(cancelled, [HOST])
	_check(cancelled.phase == CombatState.Phase.VICTORY and cancelled.enemy_block == 0 and gain not in cancelled.combat_log,
		"lethal Poison also prevents a Block action before the enemy can gain Block")


func _test_strength_and_replay() -> void:
	var data := _encounter(BUFF_GOBLIN, [BLOCK])
	var seats: Array[StringName] = [HOST, ALLY, THIRD, FOURTH]
	var first := CombatState.new(data, SEED, seats)
	var replay := CombatState.new(data, SEED, seats)
	for combat in [first, replay]:
		_expect_intent(combat, data, EnemyAction.Kind.GAIN_STRENGTH, 3)
		_end(combat, seats)
		_check(combat.enemy_strength == 3 and combat.players[HOST].hp == 36 and combat.players[FOURTH].hp == 36,
			"Strength buff changes only the enemy stat on its own turn")
		_expect_intent(combat, data, EnemyAction.Kind.ATTACK, 10)
		_play(combat, data, BLOCK)
		_end(combat, seats)
		_check(combat.players[HOST].hp == 31 and combat.players[ALLY].hp == 26 and combat.players[THIRD].hp == 26
			and combat.players[FOURTH].hp == 26, "every living Mage takes ten independently before their Block")
		_expect_intent(combat, data, EnemyAction.Kind.ATTACK, 14)
		_end(combat, seats)
		_expect_intent(combat, data, EnemyAction.Kind.GAIN_STRENGTH, 3)
		_end(combat, seats)
		_check(combat.enemy_strength == 6 and combat.players[FOURTH].hp == 12, "a repeated buff adds and persists without a hit")
		_expect_intent(combat, data, EnemyAction.Kind.ATTACK, 13)
	_check(first.combat_log == replay.combat_log and first.action_history == replay.action_history
		and Snapshot.build(first, data, FOURTH) == Snapshot.build(replay, data, FOURTH),
		"the same seed and commands reproduce the public intent and private hand")
	var cancelled := CombatState.new(data, SEED, [HOST])
	cancelled.enemy_poison = 35
	_end(cancelled, [HOST])
	_check(cancelled.phase == CombatState.Phase.VICTORY and cancelled.enemy_strength == 0,
		"lethal Poison also prevents the Strength action")


func _test_run_reset() -> void:
	var data: RunData = RUN.duplicate()
	var opening := _encounter(BLOCK_TREANT, [STRIKE])
	opening.enemy_max_hp = 6
	opening.enemy_starting_strength = 2
	data.opening_encounters = [opening]
	data.boss_encounter = BUFF_GOBLIN
	var players: Array[StringName] = [HOST, ALLY]
	var run := CoopRunState.new(data, players)
	var combat := run.active_combat
	combat.players[HOST].hp = 30
	combat.enemy_burning = 6
	_end(combat, players)
	run.observe_combat_result()
	_check(run.stage == CoopRunState.REWARD and combat.enemy_block == 8 and combat.enemy_strength == 2,
		"victorious Burning can leave the opening enemy's Block and Strength in the old encounter")
	_check(run.submit_reward(HOST, &"shieldstrike"), "host privately takes a reward")
	var host_view := run.view_fields(HOST)
	var ally_view := run.view_fields(ALLY)
	_check(host_view.reward_options.is_empty() and not ally_view.reward_options.is_empty()
		and host_view.run_deck_count == data.starting_deck.size() + 1 and ally_view.run_deck_count == data.starting_deck.size(),
		"personal reward choices and deck views remain independent")
	_check(run.submit_reward(ALLY, &"") and run.stage == CoopRunState.BOSS and run.encounter_id == 2,
		"each player's reward decision permits the next encounter")
	var fresh := run.active_combat
	_expect_intent(fresh, run.active_encounter, EnemyAction.Kind.GAIN_STRENGTH, 3)
	_check(fresh.enemy_block == 0 and fresh.enemy_strength == 0 and fresh.enemy_burning == 0
		and fresh.players[HOST].hp == 30 and fresh.players[ALLY].hp == 36,
		"the next action cycle restarts and clears enemy-only stats while retaining player HP")


func _encounter(prototype: EncounterData, cards: Array[CardData]) -> EncounterData:
	var data: EncounterData = prototype.duplicate()
	data.test_deck = cards
	return data


func _play(combat: CombatState, encounter: EncounterData, card: CardData) -> void:
	for copy in combat.players[HOST].hand:
		if combat.card_data(copy) == card:
			var target := encounter.enemy_id if card.targets_enemy() else &""
			_check(combat.play_card(HOST, copy, target), "host plays %s" % card.display_name)
			return
	_check(false, "host has %s" % card.display_name)


func _end(combat: CombatState, seats: Array[StringName]) -> void:
	for seat in seats:
		_check(combat.end_turn(seat), "%s ends their turn" % seat)


func _expect_intent(combat: CombatState, encounter: EncounterData, kind: EnemyAction.Kind, amount: int) -> void:
	var view := Snapshot.build(combat, encounter, HOST)
	_check(view.enemy_intent.kind == kind and view.enemy_intent.amount == amount and
		view.enemy_attack == (amount if kind == EnemyAction.Kind.ATTACK else 0)
		and view.enemy_block == combat.enemy_block and view.enemy_strength == combat.enemy_strength,
		"%s advertises %s %d and the same public modifiers" % [encounter.enemy_name, EnemyAction.Kind.keys()[kind], amount])


func _before(log_messages: PackedStringArray, first: String, second: String) -> bool:
	return log_messages.find(first) >= 0 and log_messages.find(second) > log_messages.find(first)


func _check(condition: bool, context: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr(context)
