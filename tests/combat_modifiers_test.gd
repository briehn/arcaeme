extends SceneTree

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const CardData = preload("res://scripts/combat/card_data.gd")
const CardEffect = preload("res://scripts/combat/card_effect.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const Snapshot = preload("res://scripts/combat/combat_view_snapshot.gd")
const BLOCK = preload("res://resources/prototype/cards/basic_block.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const PREPARATION = preload("res://resources/prototype/cards/battle_preparation.tres")
const REVERSAL = preload("res://resources/prototype/cards/arcane_reversal.tres")
const SHIELDSTRIKE = preload("res://resources/prototype/cards/shieldstrike.tres")
const RUN = preload("res://resources/prototype/battle_mage_run.tres")
const HOST := &"Battle Mage 1"
const ALLY := &"Battle Mage 2"
const ENEMY := &"modifier_fixture"
const SEED := 104774

var _checks := 0
var _failures := 0
var _sequences: Dictionary[int, int] = {}


func _initialize() -> void:
	_test_attack_and_preparation()
	_test_block_effects_and_offense()
	_test_reversal_threshold()
	_test_positive_and_unbounded_modifiers()
	_test_periodic_damage_and_replay()
	_test_lethal_multi_hit()
	_test_boss_reset()
	print("Strength and Dexterity: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _test_attack_and_preparation() -> void:
	var buffs := _buff_card(2, 2)
	var raw_damage := _card(&"non_attack", [_effect(CardEffect.Kind.DAMAGE, 3)])
	var multi := _card(&"multi_hit", [_effect(CardEffect.Kind.DAMAGE, 2),
		_effect(CardEffect.Kind.DAMAGE, 2), _effect(CardEffect.Kind.DAMAGE, 2)], true)
	var fixture := _fixture([buffs, raw_damage, multi, PREPARATION, STRIKE])
	var combat := CombatState.new(fixture, SEED, [HOST, ALLY])
	var host := combat.players[HOST]
	var ally := combat.players[ALLY]
	_check(not buffs.targets_enemy() and "2 Strength" in buffs.description() and
		"2 Dexterity" in buffs.description(), "modifier cards are self effects with readable rules")
	_check(host.strength == 0 and host.dexterity == 0 and combat.enemy_strength == 0 and
		combat.enemy_dexterity == 0, "fresh ordinary encounters default to zero modifiers")
	_play(combat, HOST, buffs)
	_check(host.strength == 2 and host.dexterity == 2 and ally.strength == 0 and ally.dexterity == 0,
		"gains apply to the caster only")
	_play(combat, HOST, PREPARATION)
	_check(host.block == 9 and host.next_attack_bonus == 3,
		"Dexterity improves Battle Preparation Block and leaves the bonus unchanged")
	_play(combat, HOST, raw_damage)
	_check(combat.enemy_hp == 97 and host.next_attack_bonus == 3,
		"non-Attack damage gets neither Strength nor preparation and leaves the bonus pending")
	_play(combat, ALLY, STRIKE)
	_check(combat.enemy_hp == 91 and host.next_attack_bonus == 3, "an ally's Attack uses only their own modifiers")
	_play(combat, HOST, multi)
	_check(combat.enemy_hp == 76 and host.next_attack_bonus == 0,
		"three 2-damage hits each gain +2 Strength and only the first gains +3 preparation")
	_check("Modifier Fixture took 7 damage." in combat.combat_log and
		combat.combat_log.count("Modifier Fixture took 4 damage.") == 2, "multi-hit log records each qualifying hit")
	_check(combat.end_turn(HOST) and combat.end_turn(ALLY), "both members can finish the round")
	_check(host.strength == 2 and host.dexterity == 2 and host.block == 0 and host.mana == 3,
		"modifiers persist across turns while Block expires and Mana refreshes")


func _test_block_effects_and_offense() -> void:
	var buffs := _buff_card(2, 2)
	var dual_block := _card(&"dual_block", [_effect(CardEffect.Kind.GAIN_BLOCK, 3),
		_effect(CardEffect.Kind.GAIN_BLOCK, 4)])
	var fixture := _fixture([buffs, dual_block, SHIELDSTRIKE, REVERSAL])
	var combat := CombatState.new(fixture, SEED, [HOST])
	_play(combat, HOST, buffs)
	_play(combat, HOST, dual_block)
	_check(combat.players[HOST].block == 11, "two Block effects gain +2 Dexterity independently")
	_play(combat, HOST, SHIELDSTRIKE)
	_check(combat.enemy_hp == 87 and combat.players[HOST].block == 11,
		"Shieldstrike adds floor(11 / 3) and Strength, preserves Block, and does not add Dexterity directly")
	_play(combat, HOST, REVERSAL)
	_check(combat.enemy_hp == 71 and combat.players[HOST].block == 5,
		"Arcane Reversal spends exactly 6 Block for +6 damage and then gains +2 Strength")


func _test_reversal_threshold() -> void:
	var buffs := _buff_card(2, 1)
	var fixture := _fixture([buffs, BLOCK, REVERSAL])
	var at_threshold := CombatState.new(fixture, SEED, [HOST])
	_play(at_threshold, HOST, buffs)
	_play(at_threshold, HOST, BLOCK)
	_check(at_threshold.players[HOST].block == 6, "one Dexterity takes Basic Block from five to six")
	_play(at_threshold, HOST, REVERSAL)
	_check(at_threshold.players[HOST].block == 0 and at_threshold.enemy_hp == 84,
		"Reversal accepts six Block and keeps its fixed spend and Strength bonus")
	var below_threshold := CombatState.new(fixture, SEED, [HOST])
	below_threshold.players[HOST].strength = 2
	_play(below_threshold, HOST, BLOCK)
	_play(below_threshold, HOST, REVERSAL)
	_check(below_threshold.players[HOST].block == 5 and below_threshold.enemy_hp == 90,
		"Reversal at five Block spends none and deals baseline damage plus Strength")


func _test_positive_and_unbounded_modifiers() -> void:
	var large_buff := _buff_card(60, 70)
	var unsupported := _card(&"negative_modifiers", [_effect(CardEffect.Kind.GAIN_STRENGTH, -5),
		_effect(CardEffect.Kind.GAIN_DEXTERITY, -4), _effect(CardEffect.Kind.GAIN_BLOCK, 0)])
	var fixture := _fixture([large_buff, large_buff, unsupported, STRIKE, BLOCK], 300)
	var combat := CombatState.new(fixture, SEED, [HOST])
	_play(combat, HOST, large_buff)
	_play(combat, HOST, large_buff)
	_play(combat, HOST, unsupported)
	_check(combat.players[HOST].strength == 120 and combat.players[HOST].dexterity == 140,
		"positive applications add without a cap and unsupported negative applications do not subtract")
	_check(combat.players[HOST].block == 0, "zero base Block does not create Block from Dexterity")
	_play(combat, HOST, STRIKE)
	_play(combat, HOST, BLOCK)
	_check(combat.enemy_hp == 174 and combat.players[HOST].block == 145,
		"damage and Block use the full modifier values above 99")


func _test_periodic_damage_and_replay() -> void:
	var buffs := _buff_card(6, 5)
	var dots := _card(&"dots", [_effect(CardEffect.Kind.APPLY_POISON, 4),
		_effect(CardEffect.Kind.APPLY_BURNING, 5)])
	var fixture := _fixture([buffs, dots, BLOCK])
	fixture.enemy_attack = 1
	fixture.enemy_starting_strength = 4
	fixture.enemy_starting_dexterity = 3
	fixture.enemy_poison_per_attack = 2
	fixture.enemy_burning_per_attack = 3
	var first := CombatState.new(fixture, SEED, [HOST, ALLY])
	var second := CombatState.new(fixture, SEED, [HOST, ALLY])
	for combat in [first, second]:
		_play(combat, HOST, buffs)
		_play(combat, HOST, dots)
		_play(combat, HOST, BLOCK)
		_check(combat.end_turn(HOST) and combat.end_turn(ALLY), "the enemy can act after the party ends")
		var turn_two := Snapshot.build(combat, fixture, HOST)
		_check(combat.enemy_hp == 91 and combat.enemy_poison == 3 and combat.enemy_burning == 3,
			"enemy Poison and Burning deal exactly their stacks despite both sides' modifiers")
		_check(turn_two.enemy_attack == 5 and turn_two.enemy_strength == 4 and turn_two.enemy_dexterity == 3,
			"public snapshot publishes enemy stats and Strength-adjusted damage intent")
		_check(combat.players[HOST].hp == 38 and combat.players[ALLY].hp == 33 and combat.players[HOST].poison == 1,
			"enemy Strength applies equally before personal Block and incoming Poison remains exactly two HP")
		_play(combat, HOST, BLOCK)
		_check(combat.end_turn(HOST), "host ends independently")
		_check(combat.players[HOST].hp == 38 and combat.players[HOST].burning == 3 and
			combat.players[HOST].block == 10 and combat.players[ALLY].hp == 33,
			"Ready preserves HP, Burning, and Dexterity-enhanced Block")
		_check(combat.end_turn(ALLY) and combat.players[HOST].hp == 32 and combat.players[ALLY].hp == 22
			and "%s lost 3 HP to Burning." % HOST in combat.combat_log,
			"Burning bypasses Block once the party closes the phase, then the normal attack and Poison resolve")
	_check(first.action_history == second.action_history and first.combat_log == second.combat_log and
		Snapshot.build(first, fixture, HOST) == Snapshot.build(second, fixture, HOST) and
		Snapshot.build(first, fixture, ALLY) == Snapshot.build(second, fixture, ALLY),
		"same seed and actions reproduce the complete log and each seat's public and private projection")


func _test_lethal_multi_hit() -> void:
	var buffs := _buff_card(2, 1)
	var attack := _card(&"lethal_multi_hit", [_effect(CardEffect.Kind.DAMAGE, 3),
		_effect(CardEffect.Kind.DAMAGE, 3), _effect(CardEffect.Kind.GAIN_BLOCK, 2)], true)
	var fixture := _fixture([buffs, attack], 5)
	fixture.enemy_attack = 100
	var combat := CombatState.new(fixture, SEED, [HOST])
	_play(combat, HOST, buffs)
	var copy := _copy_id(combat, HOST, attack.id)
	_play(combat, HOST, attack)
	_check(combat.phase == CombatState.Phase.VICTORY and combat.enemy_hp == 0 and combat.players[HOST].hp == 40,
		"lethal first hit reaches victory at zero HP without an enemy response")
	_check(combat.players[HOST].discard_pile.has(copy) and not combat.end_turn(HOST),
		"the completed Attack enters discard and terminal combat rejects further input")
	_check(combat.players[HOST].block == 3, "remaining self effects resolve after a lethal hit and before victory")


func _test_boss_reset() -> void:
	var buffs := _buff_card(2, 2)
	var opening := _fixture([buffs, STRIKE], 8)
	opening.enemy_starting_strength = 4
	opening.enemy_starting_dexterity = 3
	var run: RunData = RUN.duplicate()
	run.player_max_hp = 40
	run.opening_encounters = [opening]
	run.starting_deck = opening.test_deck.duplicate()
	var authority := Authority.new(opening, {1: HOST, 20: ALLY}, run)
	_submit(authority, 1, Authority.Command.PLAY_CARD, buffs.id)
	_submit(authority, 20, Authority.Command.PLAY_CARD, buffs.id)
	_submit(authority, 1, Authority.Command.PLAY_CARD, STRIKE.id)
	var reward := authority.snapshot_for(20)
	_check(reward.run_stage == "reward" and reward.enemy_strength == 4 and reward.enemy_dexterity == 3 and
		reward.players[0].strength == 2 and reward.players[1].dexterity == 2,
		"public encounter modifiers survive in the final reward snapshot")
	_submit(authority, 1, Authority.Command.REWARD)
	_submit(authority, 20, Authority.Command.REWARD)
	var boss := authority.snapshot_for(20)
	_check(boss.run_stage == "boss" and boss.encounter_id == 2 and boss.revision == 0 and boss.enemy_strength == 0 and
		boss.enemy_dexterity == 0 and boss.players == authority.snapshot_for(1).players,
		"fresh boss resets outgoing enemy values and publishes matching roster stats to all peers")
	for player: Dictionary in boss.players:
		_check(player.strength == 0 and player.dexterity == 0 and player.hp == 40 and player.mana == 3,
			"boss resets player modifiers while preserving carried HP and refreshing Mana")


func _fixture(cards: Array[CardData], hp := 100) -> EncounterData:
	var fixture := EncounterData.new()
	fixture.player_max_hp = 40
	fixture.enemy_id = ENEMY
	fixture.enemy_name = "Modifier Fixture"
	fixture.enemy_max_hp = hp
	fixture.test_deck = cards
	return fixture


func _buff_card(strength: int, dexterity: int) -> CardData:
	return _card(&"modifier_gains", [_effect(CardEffect.Kind.GAIN_STRENGTH, strength),
		_effect(CardEffect.Kind.GAIN_DEXTERITY, dexterity)])


func _effect(kind: CardEffect.Kind, amount: int) -> CardEffect:
	var effect := CardEffect.new()
	effect.kind = kind
	effect.amount = amount
	return effect


func _card(id: StringName, effects: Array[CardEffect], attack := false) -> CardData:
	var card := CardData.new()
	card.id = id
	card.display_name = String(id)
	card.is_attack = attack
	card.effects = effects
	return card


func _copy_id(combat: CombatState, actor: StringName, card_id: StringName) -> int:
	for copy in combat.players[actor].hand:
		if combat.card_data(copy).id == card_id:
			return copy
	return -1


func _play(combat: CombatState, actor: StringName, card: CardData) -> void:
	var target := ENEMY if card.targets_enemy() else &""
	_check(combat.play_card(actor, _copy_id(combat, actor, card.id), target), "%s plays %s" % [actor, card.id])


func _submit(authority: Authority, peer: int, kind: Authority.Command, card_id := &"") -> void:
	var view := authority.snapshot_for(peer)
	var sequence: int = _sequences.get(peer, 0) + 1
	_sequences[peer] = sequence
	var request := {"actor": view.viewer, "sequence": sequence, "kind": int(kind), "encounter_id": view.encounter_id}
	if kind == Authority.Command.REWARD:
		request["reward_id"] = ""
	else:
		request.merge({"round": view.round, "phase": view.phase, "ready_epoch": view.ready_epoch})
		for card in view.hand:
			if card.id == String(card_id):
				request["copy"] = card.copy
				if card.targets_enemy:
					request["target"] = view.enemies[0].id
				break
	_check(authority.submit(peer, request) == Authority.Result.ACCEPTED,
		"authority accepts %s from peer %d" % [Authority.Command.keys()[kind], peer])


func _check(condition: bool, context: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(context)
