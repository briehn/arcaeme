extends SceneTree

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const Snapshot = preload("res://scripts/combat/combat_view_snapshot.gd")
const DEFAULT = preload("res://resources/prototype/battle_mage_encounter.tres")
const SLIME = preload("res://resources/prototype/enemies/slime.tres")
const GOBLIN = preload("res://resources/prototype/enemies/goblin.tres")
const TREANT = preload("res://resources/prototype/enemies/treant.tres")
const BLOCK = preload("res://resources/prototype/cards/basic_block.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const RUN = preload("res://resources/prototype/battle_mage_run.tres")
const HOST := &"Battle Mage 1"
const ALLY := &"Battle Mage 2"
const THIRD := &"Battle Mage 3"
const FOURTH := &"Battle Mage 4"
const SEED := 104774

var _checks := 0
var _failures := 0
var _sequences: Dictionary[int, int] = {}


func _initialize() -> void:
	_test_patterns()
	_test_malformed_pattern_damage()
	_test_party_and_strength()
	_test_periodic_damage()
	_test_boss_reset()
	print("Enemy patterns: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _test_patterns() -> void:
	for data in [[DEFAULT, 34, [9, 9, 9, 9, 9, 9]],
			[SLIME, 28, [6, 6, 6, 6, 6, 6]],
			[GOBLIN, 35, [7, 14, 14, 7, 14, 14]],
			[TREANT, 55, [4, 4, 10, 4, 4, 10]]]:
		var original: EncounterData = data[0]
		var enemy_hp: int = data[1]
		var attacks: Array = data[2]
		_check(original.enemy_max_hp == enemy_hp and original.player_max_hp == 36 and
			original.shuffle_seed == SEED and original.test_deck == DEFAULT.test_deck,
			"%s is an opt-in enemy fixture using the established Battle Mage deck" % original.enemy_name)
		var fixture: EncounterData = original.duplicate()
		fixture.player_max_hp = 100
		var first := CombatState.new(fixture, fixture.shuffle_seed, [HOST])
		var second := CombatState.new(fixture, fixture.shuffle_seed, [HOST])
		var remaining_hp := 100
		for index in attacks.size():
			var attack: int = attacks[index]
			var before := Snapshot.build(first, fixture, HOST)
			_check(before.enemy_name == fixture.enemy_name and before.round == index + 1 and
				before.enemy_attack == attack and before.enemy_hp == enemy_hp,
				"%s round %d announces the next attack" % [fixture.enemy_name, index + 1])
			_check(first.end_turn(HOST) and second.end_turn(HOST), "independent seeded fights advance")
			remaining_hp -= attack
			_check(first.players[HOST].hp == remaining_hp and
				"%s attacks for %d damage." % [fixture.enemy_name, attack] in first.combat_log,
				"%s resolves exactly the attack it advertised" % fixture.enemy_name)
			_check(Snapshot.build(first, fixture, HOST) == Snapshot.build(second, fixture, HOST) and
				first.action_history == second.action_history,
				"%s replay matches its snapshot, log, and accepted actions" % fixture.enemy_name)


func _test_malformed_pattern_damage() -> void:
	var fixture: EncounterData = SLIME.duplicate()
	fixture.enemy_attack_pattern = PackedInt32Array([-3, 4])
	var state := CombatState.new(fixture, SEED, [HOST])
	_check(Snapshot.build(state, fixture, HOST).enemy_attack == 0 and state.end_turn(HOST),
		"a malformed negative base damage entry advertises zero and resolves")
	_check(state.players[HOST].hp == 36 and state.players[HOST].block == 0 and
		"Slime attacks for 0 damage." in state.combat_log and Snapshot.build(state, fixture, HOST).enemy_attack == 4,
		"the invalid entry neither heals nor grants Block and the next round still advances")


func _test_party_and_strength() -> void:
	var fixture: EncounterData = GOBLIN.duplicate()
	fixture.enemy_starting_strength = 2
	fixture.test_deck = [BLOCK]
	var state := CombatState.new(fixture, SEED, [HOST, ALLY, THIRD, FOURTH])
	var ready := Snapshot.build(state, fixture, HOST)
	_check(ready.enemy_attack == 9, "Strength increases the visible base pattern attack")
	_check(state.play_card(HOST, state.players[HOST].hand[0], &""), "host plays Basic Block")
	for actor in [HOST, ALLY, THIRD]:
		_check(state.end_turn(actor), "one player can end their turn")
		var waiting := Snapshot.build(state, fixture, FOURTH)
		_check(waiting.round == 1 and waiting.enemy_attack == 9 and state.players[FOURTH].hp == 36,
			"enemy keeps its intent and does no damage while any living player has not ended")
	_check(state.end_turn(FOURTH), "the final player advances the enemy phase")
	var next := Snapshot.build(state, fixture, HOST)
	_check(next.round == 2 and next.enemy_attack == 16 and state.players[HOST].hp == 32 and
		state.players[ALLY].hp == 27 and state.players[THIRD].hp == 27 and state.players[FOURTH].hp == 27,
		"all four take nine before respective Block and next intent is 14 plus two Strength")
	_check(state.players[HOST].block == 0 and state.players[HOST].mana == 3,
		"normal Block consumption and Mana refresh still apply after a patterned attack")


func _test_periodic_damage() -> void:
	var fixture: EncounterData = GOBLIN.duplicate()
	fixture.enemy_starting_strength = 2
	fixture.enemy_poison_per_attack = 3
	fixture.enemy_burning_per_attack = 5
	var state := CombatState.new(fixture, SEED, [HOST])
	state.enemy_poison = 2
	state.enemy_burning = 3
	_check(state.end_turn(HOST), "solo enemy phase resolves periodic damage and a patterned attack")
	_check(state.enemy_hp == 30 and state.enemy_poison == 1 and state.enemy_burning == 2 and
		state.players[HOST].hp == 24 and state.players[HOST].poison == 2 and state.players[HOST].burning == 5,
		"Poison and Burning bypass the pattern and Strength while the attack deals nine plus separate Poison")
	state.enemy_poison = 30
	state.players[HOST].burning = 0
	_check(state.end_turn(HOST), "a lethal Poison tick resolves at the start of the next enemy turn")
	_check(state.phase == CombatState.Phase.VICTORY and state.players[HOST].hp == 24 and
		"Goblin attacks for 16 damage." not in state.combat_log,
		"lethal Poison prevents the advertised patterned attack")


func _test_boss_reset() -> void:
	var opening: EncounterData = GOBLIN.duplicate()
	opening.enemy_max_hp = 6
	var run: RunData = RUN.duplicate()
	run.player_max_hp = 36
	run.opening_encounters = [opening]
	run.boss_encounter = TREANT
	run.starting_deck = [STRIKE]
	var authority := Authority.new(opening, {1: HOST, 20: ALLY}, run)
	for peer in [1, 20]:
		_submit(authority, peer, Authority.Command.END_TURN)
	var opening_view := authority.snapshot_for(1)
	_check(opening_view.round == 2 and opening_view.enemy_attack == 14 and opening_view.players[0].hp == 29,
		"the short run advances its opening encounter to its second pattern step")
	_submit(authority, 1, Authority.Command.PLAY_CARD)
	for peer in [1, 20]:
		_submit(authority, peer, Authority.Command.REWARD)
	var boss := authority.snapshot_for(20)
	_check(boss.run_stage == "boss" and boss.encounter_id == 2 and boss.enemy_name == "Treant" and
		boss.enemy_attack == 4 and boss.round == 1 and boss.players[0].hp == 29 and boss.players[1].hp == 29,
		"the new patterned encounter starts at round one, preserves HP, and publishes its own first intent")


func _submit(authority: Authority, peer: int, kind: Authority.Command) -> void:
	var view := authority.snapshot_for(peer)
	var sequence: int = _sequences.get(peer, 0) + 1
	_sequences[peer] = sequence
	var request := {"actor": view.viewer, "sequence": sequence, "kind": int(kind), "encounter_id": view.encounter_id}
	if kind == Authority.Command.REWARD:
		request["reward_id"] = ""
	else:
		request.merge({"round": view.round, "phase": view.phase, "ready_epoch": view.ready_epoch})
		if kind == Authority.Command.PLAY_CARD:
			request["copy"] = view.hand[0].copy
			request["target"] = view.enemies[0].id
	_check(authority.submit(peer, request) == Authority.Result.ACCEPTED, "authority accepts the scripted action")


func _check(condition: bool, context: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(context)
