extends SceneTree

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const CardData = preload("res://scripts/combat/card_data.gd")
const CardEffect = preload("res://scripts/combat/card_effect.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const ViewSnapshot = preload("res://scripts/combat/combat_view_snapshot.gd")
const BLOCK = preload("res://resources/prototype/cards/basic_block.tres")
const GUARD = preload("res://resources/prototype/cards/arcane_guard.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const RUN = preload("res://resources/prototype/battle_mage_run.tres")
const DEFAULT_ENCOUNTER = preload("res://resources/prototype/battle_mage_encounter.tres")
const HOST := &"Battle Mage 1"
const ALLY := &"Battle Mage 2"
const ENEMY := &"status_fixture"
const SEED := 104774

var _checks := 0
var _failures := 0
var _sequences: Dictionary[int, int] = {}


func _initialize() -> void:
	_test_status_free_default()
	_test_enemy_stacking_and_decay()
	_test_personal_status_timing()
	_test_personal_poison_kills_one()
	_test_enemy_poison_kill()
	_test_enemy_burning_kill_and_party_wipe()
	_test_lethal_personal_burning()
	_test_fresh_boss()
	_test_seeded_replay()
	print("Poison and Burning: %d checks, %d failures." % [_checks, _failures])
	quit(1 if _failures else 0)


func _test_status_free_default() -> void:
	var combat := CombatState.new(DEFAULT_ENCOUNTER, SEED, [HOST])
	_check(DEFAULT_ENCOUNTER.enemy_poison_per_attack == 0 and DEFAULT_ENCOUNTER.enemy_burning_per_attack == 0,
		"existing encounter resources default to no added status effects")
	combat.end_turn(HOST)
	var player := combat.players[HOST]
	_check(player.poison == 0 and player.burning == 0 and combat.enemy_poison == 0 and combat.enemy_burning == 0,
		"a plain enemy attack leaves both sides free of statuses")
	_check(player.hp == player.max_hp - DEFAULT_ENCOUNTER.enemy_attack and player.mana == 3 and player.hand.size() == 5,
		"an encounter without status effects keeps the existing direct damage and turn refresh")


func _test_enemy_stacking_and_decay() -> void:
	var poison := _status_card(&"test_poison", CardEffect.Kind.APPLY_POISON, 73)
	var burning := _status_card(&"test_burning", CardEffect.Kind.APPLY_BURNING, 5)
	var fixture := _fixture(100, 2000, 0, [poison, burning])
	var combat := CombatState.new(fixture, SEED, [HOST, ALLY])
	var copy := _copy(combat, HOST, poison.id)
	_check(poison.targets_enemy() and burning.targets_enemy() and "73 Poison" in poison.description() and
		"5 Burning" in burning.description(), "status effects target the enemy and produce readable card text")
	_check(not combat.play_card(HOST, copy, &"") and combat.players[HOST].mana == 3 and combat.enemy_poison == 0,
		"an invalid status target does not consume Mana, apply stacks, or play the card")
	for actor in [HOST, ALLY]:
		_play(combat, actor, poison.id, ENEMY)
		_play(combat, actor, burning.id, ENEMY)
	_check(combat.enemy_hp == 2000 and combat.enemy_poison == 146 and combat.enemy_burning == 10,
		"status applications add above 99 without dealing immediate damage")
	var expected_health := 2000
	var burning_before := [10, 5, 3, 2, 1]
	var burning_after := [5, 3, 2, 1, 1]
	for index in burning_before.size():
		var poison_before := 146 - index
		combat.end_turn(HOST)
		_check(combat.enemy_hp == expected_health and combat.enemy_poison == poison_before and
			combat.enemy_burning == burning_before[index], "one player ending leaves both enemy statuses untouched")
		combat.end_turn(ALLY)
		expected_health -= poison_before + burning_before[index]
		_check(combat.enemy_hp == expected_health and combat.enemy_poison == poison_before - 1 and
			combat.enemy_burning == burning_after[index], "enemy Poison loses one stack and Burning halves with upward rounding")
	var large_burning := _status_card(&"large_burning", CardEffect.Kind.APPLY_BURNING, 101)
	var large_fixture := _fixture(100, 2000, 0, [large_burning])
	var large_combat := CombatState.new(large_fixture, SEED, [HOST, ALLY])
	_play(large_combat, HOST, large_burning.id, ENEMY)
	_play(large_combat, ALLY, large_burning.id, ENEMY)
	large_combat.end_turn(HOST)
	large_combat.end_turn(ALLY)
	_check(large_combat.enemy_hp == 1798 and large_combat.enemy_burning == 101,
		"Burning stacks and deals its full damage above 99")


func _test_personal_status_timing() -> void:
	var fixture := _fixture(13, 30, 7, [BLOCK, BLOCK], 3, 5)
	var combat := CombatState.new(fixture, SEED, [HOST, ALLY])
	var host := combat.players[HOST]
	var ally := combat.players[ALLY]
	_play(combat, HOST, BLOCK.id)
	_play(combat, HOST, BLOCK.id)
	combat.end_turn(HOST)
	_check(host.hp == 13 and host.block == 10 and ally.hp == 13 and combat.round_number == 1,
		"ending one turn retains Block for the attack and leaves the other player untouched")
	combat.end_turn(ALLY)
	_check(host.hp == 10 and host.block == 0 and host.poison == 2 and host.burning == 5 and host.mana == 3,
		"the fully blocked hit still applies statuses, then remaining Block expires at the survivor's next start")
	_check(ally.hp == 3 and ally.poison == 2 and ally.burning == 5 and ally.mana == 3,
		"the unblocked player independently takes the full direct hit and start-of-turn Poison")
	_play(combat, HOST, BLOCK.id)
	_play(combat, HOST, BLOCK.id)
	combat.end_turn(HOST)
	_check(host.hp == 5 and host.block == 10 and host.burning == 3 and host.poison == 2 and host.mana == 0,
		"personal end-of-turn Burning bypasses Block and decays while Poison remains unchanged")
	_check(ally.hp == 3 and ally.burning == 5 and ally.hand.size() == 2 and not ally.ended_turn and combat.round_number == 2,
		"one end turn never ticks somebody else's Burning or advances the shared phase")
	combat.end_turn(ALLY)
	_check(combat.phase == CombatState.Phase.DEFEAT and combat.round_number == 3 and host.hp == 0 and
		host.poison == 4 and host.burning == 8 and host.hand.is_empty() and host.mana == 0,
		"lethal start-of-turn Poison prevents refresh and draws, and defeats the party when the last player falls")
	_check(ally.hp == 0 and ally.poison == 2 and ally.burning == 3 and ally.hand.is_empty() and ally.mana == 0,
		"a player killed by their own Burning has already discarded, receives no new statuses, and never ticks again")


func _test_personal_poison_kills_one() -> void:
	var fixture := _fixture(13, 30, 7, [BLOCK, BLOCK], 6, 1)
	var combat := CombatState.new(fixture, SEED, [HOST, ALLY])
	combat.end_turn(HOST)
	_play(combat, ALLY, BLOCK.id)
	_play(combat, ALLY, BLOCK.id)
	combat.end_turn(ALLY)
	var host := combat.players[HOST]
	var ally := combat.players[ALLY]
	_check(combat.phase == CombatState.Phase.PLAYER and combat.round_number == 2 and host.hp == 0 and
		host.poison == 5 and host.burning == 1 and host.mana == 0 and host.hand.is_empty() and not combat.can_end_turn(HOST),
		"lethal start Poison does not draw or refresh the first seat during a partial party defeat")
	_check(ally.hp == 7 and ally.poison == 5 and ally.burning == 1 and ally.mana == 3 and ally.hand.size() == 2 and
		combat.can_end_turn(ALLY), "the surviving later seat still receives its turn after another player falls to Poison")


func _test_enemy_poison_kill() -> void:
	var poison := _status_card(&"one_poison", CardEffect.Kind.APPLY_POISON, 1)
	var fixture := _fixture(6, 1, 7, [poison], 3, 5)
	var combat := CombatState.new(fixture, SEED, [HOST])
	_play(combat, HOST, poison.id, ENEMY)
	combat.end_turn(HOST)
	var player := combat.players[HOST]
	_check(combat.phase == CombatState.Phase.VICTORY and combat.enemy_hp == 0 and combat.enemy_poison == 0 and
		player.hp == 6 and player.poison == 0 and player.burning == 0,
		"one lethal enemy Poison stack expires before a lethal enemy attack or its status applications")


func _test_enemy_burning_kill_and_party_wipe() -> void:
	var burning := _status_card(&"one_burning", CardEffect.Kind.APPLY_BURNING, 1)
	var fixture := _fixture(6, 1, 7, [burning, BLOCK, BLOCK], 3, 5)
	var combat := CombatState.new(fixture, SEED, [HOST, ALLY])
	_play(combat, HOST, burning.id, ENEMY)
	_play(combat, HOST, BLOCK.id)
	_play(combat, HOST, BLOCK.id)
	combat.end_turn(HOST)
	combat.end_turn(ALLY)
	var survivor := combat.players[HOST]
	var recovered := combat.players[ALLY]
	_check(combat.phase == CombatState.Phase.VICTORY and combat.enemy_hp == 0 and combat.enemy_burning == 1 and
		combat.round_number == 1 and survivor.hp == 6 and survivor.block == 3 and survivor.poison == 3 and survivor.burning == 5,
		"lethal enemy Burning follows the attack and its applications, and skips the next player phase")
	_check(recovered.hp == 2 and recovered.recovered_after_victory and recovered.poison == 0 and recovered.burning == 0,
		"the direct hit kills before applying statuses, then enemy Burning victory recovers that ally at rounded-up 25%")

	var wiped := CombatState.new(fixture, SEED, [HOST, ALLY])
	_play(wiped, HOST, burning.id, ENEMY)
	wiped.end_turn(HOST)
	wiped.end_turn(ALLY)
	_check(wiped.phase == CombatState.Phase.DEFEAT and wiped.enemy_hp == 1 and wiped.enemy_burning == 1 and
		wiped.players[HOST].hp == 0 and wiped.players[ALLY].hp == 0,
		"a direct attack that wipes the party defeats it before enemy Burning could cause victory")


func _test_lethal_personal_burning() -> void:
	var poison := _status_card(&"one_poison", CardEffect.Kind.APPLY_POISON, 1)
	var fixture := _fixture(7, 1, 1, [poison, BLOCK], 2, 5)
	var combat := CombatState.new(fixture, SEED, [HOST])
	combat.end_turn(HOST)
	var player := combat.players[HOST]
	_check(player.hp == 4 and player.poison == 1 and player.burning == 5 and player.mana == 3,
		"start Poison resolves before a surviving player's normal refresh")
	_play(combat, HOST, poison.id, ENEMY)
	_play(combat, HOST, BLOCK.id)
	combat.end_turn(HOST)
	_check(combat.phase == CombatState.Phase.DEFEAT and combat.enemy_hp == 1 and combat.enemy_poison == 1 and
		combat.round_number == 2 and player.hp == 0 and player.block == 5 and player.burning == 3 and player.poison == 1,
		"the last actor's lethal Burning defeats the party before enemy Poison can resolve")
	_check(player.hand.is_empty() and player.mana == 0 and player.discard_pile.size() == 2,
		"normal hand and Mana cleanup finishes before a lethal status ends combat")


func _test_fresh_boss() -> void:
	var poison := _status_card(&"test_poison", CardEffect.Kind.APPLY_POISON, 2)
	var burning := _status_card(&"test_burning", CardEffect.Kind.APPLY_BURNING, 2)
	var opening := _fixture(13, 1, 1, [poison, burning, BLOCK], 2, 1)
	var run: RunData = RUN.duplicate()
	run.player_max_hp = 13
	run.opening_encounters = [opening]
	run.starting_deck = opening.test_deck.duplicate()
	var authority := Authority.new(opening, {1: HOST, 20: ALLY}, run)
	for peer in [1, 20]:
		_submit(authority, peer, Authority.Command.END_TURN)
	_submit(authority, 1, Authority.Command.PLAY_CARD, poison.id)
	_submit(authority, 20, Authority.Command.PLAY_CARD, burning.id)
	for peer in [1, 20]:
		_submit(authority, peer, Authority.Command.END_TURN)
	var reward := authority.snapshot_for(1)
	_check(reward.run_stage == "reward" and reward.enemy_poison == 1 and reward.enemy_burning == 2 and
		reward.players[0].hp == 9 and reward.players[1].hp == 9 and reward.players[0].poison == 1 and
		reward.players[1].poison == 1 and reward.players[0].burning == 1 and reward.players[1].burning == 1,
		"the opening result includes remaining statuses on the enemy and both players before reward settlement")
	for peer in [1, 20]:
		_submit(authority, peer, Authority.Command.REWARD)
	var host_view := authority.snapshot_for(1)
	var ally_view := authority.snapshot_for(20)
	_check(host_view.run_stage == "boss" and host_view.encounter_id == 2 and host_view.revision == 0 and
		host_view.enemy_poison == 0 and host_view.enemy_burning == 0 and host_view.players == ally_view.players and
		host_view.run_deck_count == opening.test_deck.size() and ally_view.run_deck_count == opening.test_deck.size(),
		"both peers see the same fresh boss with enemy statuses reset and both skipped decks carried")
	for player in host_view.players:
		_check(player.hp == 9 and player.max_hp == 13 and player.poison == 0 and player.burning == 0 and player.mana == 3,
			"fresh boss preserves each player's HP and resets their per-encounter statuses and Mana")


func _test_seeded_replay() -> void:
	var poison := _status_card(&"test_poison", CardEffect.Kind.APPLY_POISON, 4)
	var burning := _status_card(&"test_burning", CardEffect.Kind.APPLY_BURNING, 3)
	var mixed: CardData = STRIKE.duplicate()
	mixed.effects = STRIKE.effects.duplicate()
	mixed.effects.append(poison.effects[0])
	mixed.effects.append(burning.effects[0])
	var fixture := _fixture(24, 90, 7, [mixed, BLOCK, BLOCK, GUARD], 2, 3)
	var first := CombatState.new(fixture, SEED, [HOST, ALLY])
	var repeat := CombatState.new(fixture, SEED, [HOST, ALLY])
	for round_index in 2:
		for combat in [first, repeat]:
			_play(combat, HOST, mixed.id, ENEMY)
			_play(combat, HOST, BLOCK.id)
			_play(combat, ALLY, GUARD.id)
			_play(combat, ALLY, mixed.id, ENEMY)
			combat.end_turn(HOST)
			combat.end_turn(ALLY)
		_check(first.action_history.size() == 6 * (round_index + 1) and first.action_history == repeat.action_history and
			first.combat_log == repeat.combat_log and ViewSnapshot.build(first, fixture, HOST) == ViewSnapshot.build(repeat, fixture, HOST) and
			ViewSnapshot.build(first, fixture, ALLY) == ViewSnapshot.build(repeat, fixture, ALLY),
			"repeating the seed and mixed commands reproduces every action, log entry and both viewers' snapshots")
	_check(first.enemy_hp == 28 and first.enemy_poison == 14 and first.enemy_burning == 5 and
		first.players[HOST].hp == 12 and first.players[ALLY].hp == 16 and
		first.players[HOST].poison == 2 and first.players[ALLY].burning == 5,
		"mixed strike damage and status application coexist with normal Block and both sides' status ticks")


func _fixture(player_hp: int, enemy_hp: int, attack: int, deck: Array[CardData],
		poison := 0, burning := 0) -> EncounterData:
	var fixture := EncounterData.new()
	fixture.player_max_hp = player_hp
	fixture.enemy_id = ENEMY
	fixture.enemy_name = "Status Fixture"
	fixture.enemy_max_hp = enemy_hp
	fixture.enemy_attack = attack
	fixture.enemy_poison_per_attack = poison
	fixture.enemy_burning_per_attack = burning
	fixture.test_deck = deck
	return fixture


func _status_card(id: StringName, kind: CardEffect.Kind, amount: int) -> CardData:
	var effect := CardEffect.new()
	effect.kind = kind
	effect.amount = amount
	var card := CardData.new()
	card.id = id
	card.display_name = String(id)
	card.mana_cost = 1
	card.effects = [effect]
	return card


func _copy(combat: CombatState, actor: StringName, card_id: StringName) -> int:
	for copy_id in combat.players[actor].hand:
		if combat.card_data(copy_id).id == card_id:
			return copy_id
	return -1


func _play(combat: CombatState, actor: StringName, card_id: StringName, target: StringName = &"") -> void:
	_check(combat.play_card(actor, _copy(combat, actor, card_id), target), "%s plays %s" % [actor, card_id])


func _submit(authority: Authority, peer: int, kind: Authority.Command, card_id: StringName = &"") -> void:
	var snapshot := authority.snapshot_for(peer)
	var sequence: int = _sequences.get(peer, 0) + 1
	_sequences[peer] = sequence
	var request := {"actor": snapshot.viewer, "sequence": sequence, "kind": int(kind), "encounter_id": snapshot.encounter_id}
	if kind == Authority.Command.REWARD:
		request["reward_id"] = ""
	else:
		request.merge({"round": snapshot.round, "phase": snapshot.phase})
		if kind == Authority.Command.PLAY_CARD:
			for card in snapshot.hand:
				if card.id == String(card_id):
					request["copy"] = card.copy
					break
	_check(authority.submit(peer, request) == Authority.Result.ACCEPTED,
		"authority accepts %s from peer %d" % [Authority.Command.keys()[kind], peer])


func _check(condition: bool, context: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(context)
