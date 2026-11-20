extends SceneTree

const CardData = preload("res://scripts/combat/card_data.gd")
const CardEffect = preload("res://scripts/combat/card_effect.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const EnemyAction = preload("res://scripts/combat/enemy_action.gd")
const EnemyData = preload("res://scripts/combat/enemy_data.gd")
const Snapshot = preload("res://scripts/combat/combat_view_snapshot.gd")
const CoopRunState = preload("res://scripts/run/coop_run_state.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const TWO_SLIMES = preload("res://resources/prototype/enemies/two_slimes.tres")
const GOBLIN_TREANT = preload("res://resources/prototype/enemies/goblin_treant.tres")
const THREE_ENEMIES = preload("res://resources/prototype/enemies/three_enemies.tres")
const RUN = preload("res://resources/prototype/battle_mage_run.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const BLOCK = preload("res://resources/prototype/cards/basic_block.tres")
const GUARD = preload("res://resources/prototype/cards/arcane_guard.tres")
const PREP = preload("res://resources/prototype/cards/battle_preparation.tres")
const REVERSAL = preload("res://resources/prototype/cards/arcane_reversal.tres")
const SHIELDSTRIKE = preload("res://resources/prototype/cards/shieldstrike.tres")
const SALVO = preload("res://resources/prototype/cards/expansion/astral_salvo.tres")
const WARDED = preload("res://resources/prototype/cards/expansion/warded_strike.tres")
const STUDY = preload("res://resources/prototype/cards/expansion/arcane_study.tres")
const PRISM = preload("res://resources/prototype/cards/expansion/prism_wall.tres")
const CUT = preload("res://resources/prototype/cards/expansion/rune_cut.tres")
const FORGE = preload("res://resources/prototype/cards/expansion/spellforge.tres")

const MAGE := &"Battle Mage 1"
const ALLY := &"Battle Mage 2"
const LEFT := &"left"
const RIGHT := &"right"
const LAST := &"last"
const ROSTER: Array[StringName] = [MAGE, ALLY, &"Battle Mage 3", &"Battle Mage 4"]
const SEED := 104774

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_fixture_rosters()
	_test_card_targeting_catalogue()
	_test_invalid_and_stale_targets()
	_test_repeat_hits_and_self_effects()
	_test_independent_statuses_and_order()
	_test_victory_during_enemy_phase()
	_test_party_wipe()
	_test_rewards_and_recovery()
	print("Multi-enemy combat: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _test_fixture_rosters() -> void:
	for fixture: EncounterData in [TWO_SLIMES, GOBLIN_TREANT, THREE_ENEMIES]:
		var combat := CombatState.new(fixture, SEED, [MAGE, ALLY])
		var public := Snapshot.build(combat, fixture, MAGE)
		var ally := Snapshot.build(combat, fixture, ALLY)
		var expected_count := 3 if fixture == THREE_ENEMIES else 2
		_check(combat.enemies.size() == expected_count and public.enemies.size() == expected_count,
			"fixture exposes the entire ordered enemy roster")
		_check(public.enemies == ally.enemies and public.hand != ally.hand,
			"enemy records are public and combat copy IDs are personal")
		var ids := {}
		for i in expected_count:
			var enemy := combat.enemies[i]
			var record: Dictionary = public.enemies[i]
			_check(not ids.has(enemy.id) and combat.enemy_state(enemy.id) == enemy
				and String(enemy.id) == record.id and enemy.display_name == record.name
				and record.hp == enemy.max_hp and record.max_hp == enemy.max_hp and record.alive
				and record.intent == enemy.intent(), "fixture has a unique stable ID and matching base intent")
			ids[enemy.id] = true
		if fixture == TWO_SLIMES:
			_check(combat.enemies[0].display_name == "Slime" and combat.enemies[1].display_name == "Slime",
				"duplicate Slimes retain the same species name")
		elif fixture == GOBLIN_TREANT:
			_check(combat.enemies[0].display_name == "Goblin" and combat.enemies[1].display_name == "Treant"
				and combat.enemies[0].intent().kind != combat.enemies[1].intent().kind,
				"Goblin and Treant retain their species names and demonstrate distinct actions")
	var single: EncounterData = GOBLIN_TREANT.duplicate()
	single.enemies = [GOBLIN_TREANT.enemies[1]]
	var solo := CombatState.new(single, SEED, [MAGE])
	var view := Snapshot.build(solo, single, MAGE)
	_check(view.enemy_name == "Treant" and view.enemy_max_hp == single.enemies[0].max_hp,
		"an authored single enemy uses its own species name and HP in the legacy HUD")


func _test_card_targeting_catalogue() -> void:
	for card: CardData in [STRIKE, REVERSAL, SHIELDSTRIKE, SALVO, WARDED, CUT]:
		_check(card.targets_enemy(), "%s selects one enemy" % card.display_name)
	for card: CardData in [BLOCK, GUARD, PREP, STUDY, PRISM, FORGE]:
		_check(not card.targets_enemy(), "%s has only player-side effects" % card.display_name)
	for kind in [CardEffect.Kind.APPLY_POISON, CardEffect.Kind.APPLY_BURNING]:
		_check(_effect(kind, 3).targets_enemy(), "each existing offensive status selects an enemy")


func _test_invalid_and_stale_targets() -> void:
	var data := _encounter([_enemy(LEFT, 6), _enemy(RIGHT, 12)], [STRIKE, BLOCK])
	var combat := CombatState.new(data, SEED, [MAGE, ALLY])
	var strike := _copy(combat, MAGE, STRIKE)
	var block := _copy(combat, MAGE, BLOCK)
	var start := Snapshot.build(combat, data, MAGE)
	for target in [&"", &"missing", data.enemy_id]:
		_check(not combat.can_play_card(MAGE, strike, target) and not combat.play_card(MAGE, strike, target),
			"a targeted card rejects the blank, unknown, or encounter-level ID")
	_check(not combat.can_play_card(MAGE, block, RIGHT) and not combat.play_card(MAGE, block, RIGHT),
		"a defensive card refuses an enemy ID")
	_check(Snapshot.build(combat, data, MAGE) == start and combat.action_history.is_empty(),
		"invalid targets leave all observable state and command history unchanged")
	_check(combat.play_card(MAGE, block, &"") and combat.players[MAGE].block == 5,
		"a defensive card uses its caster with an empty target")
	_check(combat.play_card(MAGE, strike, LEFT) and combat.enemies[0].hp == 0
		and combat.enemies[1].hp == 12 and combat.phase == CombatState.Phase.PLAYER,
		"the first defeat affects only the selected target and leaves combat active")
	var public := Snapshot.build(combat, data, ALLY)
	_check(not public.enemies[0].alive and public.enemies[0].intent.is_empty()
		and public.enemies[1].alive, "snapshots retain defeated enemies without an active intent")
	var ally_copy := _copy(combat, ALLY, STRIKE)
	_check(not combat.can_play_card(ALLY, ally_copy, LEFT) and not combat.play_card(ALLY, ally_copy, LEFT),
		"a later seat cannot act on a target already defeated by another seat")
	_check(Snapshot.build(combat, data, ALLY) == public and combat.players[ALLY].discard_pile.is_empty(),
		"a stale command preserves the card, Mana, state, log, and revision")
	_check(combat.play_card(ALLY, ally_copy, RIGHT) and combat.enemies[1].hp == 6
		and combat.action_history.back().target == RIGHT,
		"the ally can resubmit the same card with the remaining valid target")


func _test_repeat_hits_and_self_effects() -> void:
	var data := _encounter([_enemy(LEFT, 4), _enemy(RIGHT, 22), _enemy(LAST, 4)], [PREP, SALVO, WARDED])
	var combat := CombatState.new(data, SEED, [MAGE, ALLY])
	combat.players[MAGE].strength = 2
	combat.enemies[1].block = 3
	_play(combat, MAGE, PREP, &"")
	_play(combat, MAGE, SALVO, RIGHT)
	_check(combat.enemies[0].hp == 4 and combat.enemies[1].hp == 4 and combat.enemies[1].block == 0
		and combat.enemies[2].hp == 4 and combat.players[MAGE].next_attack_bonus == 0,
		"Salvo spends target Block per hit and applies Strength twice, preparation once")
	_play(combat, ALLY, SALVO, LEFT)
	_check(combat.enemies[0].hp == 0 and combat.enemies[1].hp == 4 and combat.enemies[2].hp == 4,
		"Salvo's second effect does not retarget after the first hit is lethal")
	combat.players[ALLY].strength = 1
	combat.players[ALLY].dexterity = 2
	_play(combat, ALLY, WARDED, RIGHT)
	_check(combat.enemies[1].hp == 0 and combat.enemies[2].hp == 4 and combat.players[ALLY].block == 6,
		"Warded Strike keeps granting its caster Block after a lethal hit")


func _test_independent_statuses_and_order() -> void:
	var statuses := CardData.new()
	statuses.id = &"test_statuses"
	statuses.effects = [_effect(CardEffect.Kind.APPLY_POISON, 5), _effect(CardEffect.Kind.APPLY_BURNING, 5)]
	var left := _enemy(LEFT, 5, 20)
	left.starting_dexterity = 2
	left.poison_per_attack = 7
	var right := _enemy(RIGHT, 5)
	right.display_name = "Treant"
	right.starting_dexterity = 4
	right.burning_per_attack = 4
	right.action_cycle = [_action(EnemyAction.Kind.BLOCK, 8)]
	var last := _enemy(LAST, 20)
	last.display_name = "Goblin"
	last.starting_strength = 1
	last.poison_per_attack = 1
	last.burning_per_attack = 2
	last.action_cycle = [_action(EnemyAction.Kind.GAIN_STRENGTH, 3), _action(EnemyAction.Kind.ATTACK, 6)]
	var data := _encounter([left, right, last], [statuses, BLOCK])
	var combat := CombatState.new(data, SEED, ROSTER)
	var first := combat.enemies[0]
	var second := combat.enemies[1]
	var third := combat.enemies[2]
	first.block = 4
	second.burning = 5
	_play(combat, MAGE, statuses, LEFT)
	_check(first.poison == 5 and first.burning == 5 and second.poison == 0 and second.burning == 5
		and third.poison == 0 and third.burning == 0 and first.dexterity == 2 and second.dexterity == 4,
		"targeted statuses and starting modifiers belong to distinct enemy instances")
	_end(combat, [MAGE, ALLY, ROSTER[2]])
	_check(combat.round_number == 1 and first.hp == 5 and first.block == 4
		and second.hp == 5 and third.strength == 1, "the shared phase waits for the fourth living seat")
	_end(combat, [ROSTER[3]])
	_check(first.hp == 0 and first.block == 0 and first.poison == 4
		and first.burning == 5 and first.action_index == 0,
		"Block expires before lethal Poison, with no action or Burning tick for that enemy")
	_check(second.hp == 0 and second.burning == 3 and second.block == 8 and second.action_index == 1,
		"the second enemy still acts, gains fixed Block, then takes lethal Burning through it")
	_check(third.hp == 20 and third.strength == 4 and third.action_index == 1 and third.intent().amount == 10
		and combat.round_number == 2 and combat.players[MAGE].hp == 36
		and combat.players[MAGE].poison == 0 and combat.players[MAGE].burning == 0,
		"the last enemy buffs, and self actions never apply their off-turn attack payloads")
	_check(_log_before(combat, "Slime lost 4 remaining Block at action start.", "Slime lost 5 HP to Poison.")
		and _log_before(combat, "Slime lost 5 HP to Poison.", "Treant gained 8 Block.")
		and _log_before(combat, "Treant gained 8 Block.", "Treant lost 5 HP to Burning.")
		and _log_before(combat, "Treant lost 5 HP to Burning.", "Goblin gained 3 Strength."),
		"each enemy completes its own boundary sequence in fixed roster order")
	_play(combat, MAGE, BLOCK, &"")
	_end(combat, ROSTER)
	for player in ROSTER:
		var seat := combat.players[player]
		_check(seat.hp == (30 if player == MAGE else 25) and seat.poison == 0 and seat.burning == 2,
			"the surviving enemy attacks all living Mages for ten before personal Block and applies its own payload")
	_check(first.action_index == 0 and second.action_index == 1 and third.action_index == 2
		and third.intent().kind == EnemyAction.Kind.GAIN_STRENGTH,
		"defeated enemies stay stopped as the surviving cycle repeats")


func _test_victory_during_enemy_phase() -> void:
	var data := _encounter([_enemy(LEFT, 1, 9), _enemy(RIGHT, 1, 2)], [STRIKE])
	var combat := CombatState.new(data, SEED, [MAGE])
	combat.enemies[0].poison = 1
	combat.enemies[1].burning = 1
	_end(combat, [MAGE])
	_check(combat.phase == CombatState.Phase.VICTORY and combat.round_number == 1
		and combat.enemies[0].action_index == 0 and combat.enemies[1].action_index == 1
		and combat.players[MAGE].hp == 34, "the final enemy's Burning opens victory without an extra player phase")


func _test_party_wipe() -> void:
	var data := _encounter([_enemy(LEFT, 6, 4), _enemy(RIGHT, 6, 6)], [STRIKE])
	var combat := CombatState.new(data, SEED, [MAGE, ALLY], 4)
	combat.enemies[0].burning = 6
	_end(combat, [MAGE, ALLY])
	_check(combat.phase == CombatState.Phase.DEFEAT and combat.players[MAGE].hp == 0 and combat.players[ALLY].hp == 0,
		"a full-party wipe concludes the encounter as a defeat")
	_check(combat.enemies[0].hp == 6 and combat.enemies[0].burning == 6 and combat.enemies[0].action_index == 1
		and combat.enemies[1].hp == 6 and combat.enemies[1].action_index == 0,
		"the provisional wipe boundary stops Burning and later actions immediately")


func _test_rewards_and_recovery() -> void:
	var data: RunData = RUN.duplicate()
	var first := _enemy(LEFT, 6, 4)
	var second := _enemy(RIGHT, 6, 1)
	second.action_cycle = [_action(EnemyAction.Kind.ATTACK, 1), _action(EnemyAction.Kind.BLOCK, 8)]
	data.opening_encounters = [_encounter([first, second], [STRIKE, STRIKE, BLOCK])]
	data.starting_deck = [STRIKE, STRIKE, BLOCK]
	var run := CoopRunState.new(data, [MAGE, ALLY])
	var combat := run.active_combat
	combat.players[ALLY].hp = 3
	_play(combat, MAGE, BLOCK, &"")
	_end(combat, [MAGE, ALLY])
	_check(combat.players[MAGE].hp == 36 and combat.players[ALLY].hp == 0 and combat.phase == CombatState.Phase.PLAYER,
		"enemy attacks respect the caster's Block and skip the already-defeated ally")
	_play(combat, MAGE, STRIKE, LEFT)
	run.observe_combat_result()
	_check(run.stage == CoopRunState.OPENING and run.encounter_id == 1 and combat.players[ALLY].hp == 0
		and not run.view_fields(ALLY).has("reward_options"), "the first enemy's defeat opens neither recovery nor rewards")
	_play(combat, MAGE, STRIKE, RIGHT)
	run.observe_combat_result()
	_check(combat.phase == CombatState.Phase.VICTORY and run.stage == CoopRunState.REWARD
		and combat.players[MAGE].hp == 36 and combat.players[ALLY].hp == 9 and combat.players[ALLY].recovered_after_victory,
		"the last defeat opens rewards and triggers confirmed post-victory recovery")
	_check(run.submit_reward(ALLY, &"shieldstrike") and run.view_fields(ALLY).reward_options.is_empty()
		and not run.view_fields(MAGE).reward_options.is_empty(), "a recovered ally's reward remains private")
	_check(run.submit_reward(MAGE, &"") and run.stage == CoopRunState.BOSS and run.encounter_id == 2
		and run.active_combat.enemies.size() == 1 and run.active_combat.players[ALLY].hp == 9
		and run.view_fields(ALLY).run_deck_count == 4 and run.view_fields(MAGE).run_deck_count == 3,
		"both decisions start the legacy single-enemy boss with personal carryover")


func _encounter(enemies: Array[EnemyData], cards: Array[CardData]) -> EncounterData:
	var data := EncounterData.new()
	data.player_max_hp = 36
	data.enemy_id = &"prototype_fixture"
	data.enemies = enemies
	data.test_deck = cards
	return data


func _enemy(id: StringName, hp: int, attack := 0) -> EnemyData:
	var enemy := EnemyData.new()
	enemy.id = id
	enemy.display_name = "Slime"
	enemy.max_hp = hp
	enemy.attack = attack
	return enemy


func _action(kind: EnemyAction.Kind, amount: int) -> EnemyAction:
	var action := EnemyAction.new()
	action.kind = kind
	action.amount = amount
	return action


func _effect(kind: CardEffect.Kind, amount: int) -> CardEffect:
	var effect := CardEffect.new()
	effect.kind = kind
	effect.amount = amount
	return effect


func _copy(combat: CombatState, player: StringName, card: CardData) -> int:
	for copy_id in combat.players[player].hand:
		if combat.card_data(copy_id) == card:
			return copy_id
	return -1


func _play(combat: CombatState, player: StringName, card: CardData, target: StringName) -> void:
	var copy_id := _copy(combat, player, card)
	_check(copy_id >= 0 and combat.play_card(player, copy_id, target), "%s plays %s" % [player, card.display_name])


func _end(combat: CombatState, roster: Array[StringName]) -> void:
	for player in roster:
		_check(combat.end_turn(player), "%s ends their turn" % player)


func _log_before(combat: CombatState, first: String, second: String) -> bool:
	var index := combat.combat_log.find(first)
	return index >= 0 and combat.combat_log.find(second) > index


func _check(condition: bool, context: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr(context)
