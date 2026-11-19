extends SceneTree

const CombatState = preload("res://scripts/combat/combat_state.gd")
const CardData = preload("res://scripts/combat/card_data.gd")
const CardEffect = preload("res://scripts/combat/card_effect.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const ENCOUNTER = preload("res://resources/prototype/battle_mage_encounter.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const BLOCK = preload("res://resources/prototype/cards/basic_block.tres")
const GUARD = preload("res://resources/prototype/cards/arcane_guard.tres")
const SHIELDSTRIKE = preload("res://resources/prototype/cards/shieldstrike.tres")
const REVERSAL = preload("res://resources/prototype/cards/arcane_reversal.tres")
const PREPARATION = preload("res://resources/prototype/cards/battle_preparation.tres")
const MAGE := &"Battle Mage"
const ALLY := &"Second tester"

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_opening_and_validation()
	_test_card_effects_and_block_timing()
	_test_draw_piles_and_hand_cleanup()
	_test_draw_effect_has_no_hand_cap()
	_test_arcane_reversal_thresholds()
	_test_battle_preparation()
	_test_synergies_and_order()
	_test_shared_phase()
	_test_terminal_states()
	_test_replay()
	print("Combat state: %d checks, %d failures." % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _test_opening_and_validation() -> void:
	var data := _fixture([STRIKE, STRIKE, STRIKE, STRIKE, STRIKE, STRIKE])
	var state := CombatState.new(data, data.shuffle_seed, [MAGE])
	var player := state.players[MAGE]
	_check(player.hp == data.player_max_hp and state.enemy_hp == data.enemy_max_hp,
		"HP starts at the configured maxima")
	_check(state.round_number == 1 and player.mana == 3 and player.hand.size() == 5,
		"the first turn starts with 3 Mana and draws exactly 5 cards")
	var first_copy := player.hand[0]
	_check(not state.play_card(ALLY, first_copy, data.enemy_id), "reject an unknown actor")
	_check(not state.play_card(MAGE, first_copy, &"wrong_target"), "reject an invalid enemy target")
	_check(not state.play_card(MAGE, player.draw_pile[0], data.enemy_id), "reject a card outside the hand")
	_check(player.mana == 3 and player.hand.size() == 5 and state.action_history.is_empty(),
		"rejections preserve Mana, hand and action order")
	_check(state.play_card(MAGE, first_copy, data.enemy_id), "play a card from the hand")
	_check(state.enemy_hp == data.enemy_max_hp - 6 and player.mana == 2, "deal damage and pay Mana")
	_check(player.discard_pile == [first_copy], "played copy enters discard")
	_check(not state.play_card(MAGE, first_copy, data.enemy_id), "reject replaying a removed copy")
	_check(state.play_card(MAGE, player.hand[0], data.enemy_id), "play a distinct copy with the same card ID")
	_check(state.play_card(MAGE, player.hand[0], data.enemy_id), "spend the last Mana")
	_check(player.mana == 0 and player.hand.size() == 2, "hand and Mana track the three plays")
	_check(not state.play_card(MAGE, player.hand[0], data.enemy_id), "reject insufficient Mana")


func _test_card_effects_and_block_timing() -> void:
	var data := _fixture([BLOCK, GUARD, SHIELDSTRIKE])
	var state := CombatState.new(data, data.shuffle_seed, [MAGE])
	var player := state.players[MAGE]
	var block_copy := _find_copy(state, &"basic_block")
	_check(not state.play_card(MAGE, block_copy, data.enemy_id), "reject an enemy target for a self card")
	_check(state.play_card(MAGE, block_copy, &"") and player.block == 5, "Basic Block grants 5 Block")
	_check(state.play_card(MAGE, _find_copy(state, &"arcane_guard"), &""), "play Arcane Guard")
	_check(player.block == 12 and player.hand.has(block_copy), "Arcane Guard grants Block and draws from discard")
	_check(state.play_card(MAGE, _find_copy(state, &"shieldstrike"), data.enemy_id), "play Shieldstrike")
	_check(state.enemy_hp == data.enemy_max_hp - 12 and player.block == 12,
		"Shieldstrike adds one damage per full group of Block and preserves Block")
	_check(state.end_turn(MAGE), "end the turn")
	_check(player.hp == data.player_max_hp and player.block == 0,
		"Block absorbs the enemy hit, then leftover Block expires on the next turn")
	_check("Battle Mage blocked 9 and lost 0 HP." in state.combat_log and
		"Battle Mage lost 3 remaining Block at turn start." in state.combat_log,
		"the log records mitigation before Block expiry")
	_check(state.round_number == 2 and player.mana == 3, "the next personal turn refreshes Mana")
	_check(state.play_card(MAGE, _find_copy(state, &"shieldstrike"), data.enemy_id),
		"Shieldstrike is useful with zero Block")
	_check(state.enemy_hp == data.enemy_max_hp - 20, "Shieldstrike deals its base damage at zero Block")
	_check(state.play_card(MAGE, _find_copy(state, &"basic_block"), &""), "play a partial defense")
	state.end_turn(MAGE)
	_check(player.hp == data.player_max_hp - 4, "damage beyond Block reaches HP")


func _test_draw_piles_and_hand_cleanup() -> void:
	var data := _fixture([GUARD])
	var state := CombatState.new(data, data.shuffle_seed, [MAGE])
	var player := state.players[MAGE]
	_check(player.hand.size() == 1 and player.draw_pile.is_empty(), "draw stops when both piles run out")
	var copy := player.hand[0]
	state.play_card(MAGE, copy, &"")
	_check(player.hand.is_empty() and player.discard_pile == [copy],
		"a resolving draw card remains outside discard until its effects finish")
	state.end_turn(MAGE)
	_check(player.hand == [copy] and player.discard_pile.is_empty(), "reshuffle the discard when draw is empty")
	state.end_turn(MAGE)
	_check(player.hand == [copy] and player.discard_pile.is_empty(), "unplayed cards can enter the reshuffle")
	var mixed_data := _fixture([STRIKE, BLOCK, STRIKE, BLOCK, STRIKE, BLOCK, STRIKE])
	mixed_data.enemy_attack = 0
	var mixed := CombatState.new(mixed_data, mixed_data.shuffle_seed, [MAGE])
	var mixed_player := mixed.players[MAGE]
	var last_in_draw: int = mixed_player.draw_pile.back()
	mixed.end_turn(MAGE)
	_check(mixed_player.hand.size() == 5 and mixed_player.hand[0] == last_in_draw,
		"draw the last cards before reshuffling, then complete the five-card draw")
	_check(mixed_player.draw_pile.size() == 2 and mixed_player.discard_pile.is_empty(),
		"mixed-pile draw conserves all copies")
	for round_index in 4:
		mixed.play_card(MAGE, _find_copy(mixed, &"basic_strike"), mixed_data.enemy_id)
		mixed.end_turn(MAGE)
		var copies := mixed_player.hand + mixed_player.draw_pile + mixed_player.discard_pile
		copies.sort()
		_check(copies == [0, 1, 2, 3, 4, 5, 6], "round %d neither duplicates nor loses card copies" % round_index)


func _test_draw_effect_has_no_hand_cap() -> void:
	var draw_effect := CardEffect.new()
	draw_effect.kind = CardEffect.Kind.DRAW
	draw_effect.amount = 3
	var draw_card: CardData = GUARD.duplicate()
	draw_card.effects = [draw_effect]
	var data := _fixture([draw_card, draw_card, draw_card, draw_card, draw_card, draw_card, draw_card, draw_card])
	var state := CombatState.new(data, data.shuffle_seed, [MAGE])
	var player := state.players[MAGE]
	var copy := player.hand[0]
	state.play_card(MAGE, copy, &"")
	_check(player.hand.size() == 7 and player.draw_pile.is_empty() and player.discard_pile == [copy],
		"a card draw can take the hand past five cards and conserves all copies")


func _test_arcane_reversal_thresholds() -> void:
	var data := _fixture([REVERSAL])
	for starting_block in [0, 3, 5, 6, 10]:
		var state := CombatState.new(data, data.shuffle_seed, [MAGE])
		var player := state.players[MAGE]
		player.block = starting_block
		var copy := player.hand[0]
		var context := "Arcane Reversal from %d Block" % starting_block
		_check(state.play_card(MAGE, copy, data.enemy_id), context + " is playable")
		var should_spend: bool = starting_block >= 6
		var damage := 14 if should_spend else 8
		_check(state.enemy_hp == data.enemy_max_hp - damage, context + " deals %d damage" % damage)
		_check(player.block == starting_block - (6 if should_spend else 0), context + " spends exactly 6 or 0 Block")
		_check(player.mana == 2 and player.hand.is_empty() and player.discard_pile == [copy],
			context + " costs one Mana and discards the resolved copy")
		var event := "Arcane Reversal spent 6 Block for +6 damage." if should_spend else (
			"Arcane Reversal needs 6 Block for bonus damage. Battle Mage has %d Block and spent none." % starting_block)
		_check(event in state.combat_log and "Training Golem took %d damage." % damage in state.combat_log,
			context + " logs the conditional result and the damage")
	data.enemy_max_hp = 8
	var lethal := CombatState.new(data, data.shuffle_seed, [MAGE])
	lethal.players[MAGE].block = 6
	var lethal_copy := lethal.players[MAGE].hand[0]
	lethal.play_card(MAGE, lethal_copy, data.enemy_id)
	_check(lethal.phase == CombatState.Phase.VICTORY and lethal.players[MAGE].block == 0 and
		lethal.players[MAGE].discard_pile == [lethal_copy],
		"Arcane Reversal completes the automatic spend and discard even when its base damage is lethal")


func _test_battle_preparation() -> void:
	var data := _fixture([PREPARATION, STRIKE, STRIKE])
	var state := CombatState.new(data, data.shuffle_seed, [MAGE])
	var player := state.players[MAGE]
	var preparation_copy := _find_copy(state, &"battle_preparation")
	_check(state.play_card(MAGE, preparation_copy, &""), "play Battle Preparation")
	_check(player.block == 7 and player.mana == 2 and player.next_attack_bonus == 3 and
		player.discard_pile == [preparation_copy], "Battle Preparation grants Block and a pending bonus for one Mana")
	state.play_card(MAGE, _find_copy(state, &"basic_strike"), data.enemy_id)
	_check(state.enemy_hp == data.enemy_max_hp - 9 and player.next_attack_bonus == 0,
		"the next Basic Strike receives the bonus exactly once")
	state.play_card(MAGE, _find_copy(state, &"basic_strike"), data.enemy_id)
	_check(state.enemy_hp == data.enemy_max_hp - 15 and player.mana == 0 and player.block == 7,
		"a second Strike deals only base damage and keeps the Block")

	var party_data := _fixture([PREPARATION, BLOCK, STRIKE])
	var party := CombatState.new(party_data, party_data.shuffle_seed, [MAGE, ALLY])
	var mage := party.players[MAGE]
	party.play_card(MAGE, _find_copy(party, &"battle_preparation"), &"")
	party.play_card(MAGE, _find_copy(party, &"basic_block"), &"")
	_check(mage.next_attack_bonus == 3, "a defensive card does not consume preparation")
	_check(not party.play_card(MAGE, _find_copy(party, &"basic_strike"), &"wrong_target") and
		mage.next_attack_bonus == 3, "a rejected Attack does not consume preparation")
	party.play_card(ALLY, _find_copy(party, &"basic_strike", ALLY), party_data.enemy_id)
	_check(party.enemy_hp == party_data.enemy_max_hp - 6 and mage.next_attack_bonus == 3,
		"an ally's Attack does not receive or consume the owner's bonus")
	party.end_turn(MAGE)
	_check(mage.next_attack_bonus == 0 and party.round_number == 1 and
		"Battle Mage's next Attack bonus expired at turn end." in party.combat_log,
		"preparation expires at the owner's turn end while the shared phase is still active")
	party.end_turn(ALLY)
	party.play_card(MAGE, _find_copy(party, &"basic_strike"), party_data.enemy_id)
	_check(party.enemy_hp == party_data.enemy_max_hp - 12, "the owner's Attack next turn has no expired bonus")

	var stacked_data := _fixture([PREPARATION, PREPARATION, STRIKE])
	var stacked := CombatState.new(stacked_data, stacked_data.shuffle_seed, [MAGE])
	stacked.play_card(MAGE, _find_copy(stacked, &"battle_preparation"), &"")
	stacked.play_card(MAGE, _find_copy(stacked, &"battle_preparation"), &"")
	_check(stacked.players[MAGE].next_attack_bonus == 6, "two preparations stack for the same next Attack in the fixture")
	stacked.play_card(MAGE, _find_copy(stacked, &"basic_strike"), stacked_data.enemy_id)
	_check(stacked.enemy_hp == stacked_data.enemy_max_hp - 12 and stacked.players[MAGE].next_attack_bonus == 0,
		"one Attack consumes the full stacked bonus")


func _test_synergies_and_order() -> void:
	var data := _fixture([GUARD, PREPARATION, REVERSAL, SHIELDSTRIKE, STRIKE])
	var guard_first := CombatState.new(data, data.shuffle_seed, [MAGE])
	guard_first.play_card(MAGE, _find_copy(guard_first, &"arcane_guard"), &"")
	guard_first.play_card(MAGE, _find_copy(guard_first, &"shieldstrike"), data.enemy_id)
	_check(guard_first.enemy_hp == data.enemy_max_hp - 10 and guard_first.players[MAGE].block == 7,
		"Arcane Guard makes Shieldstrike deal 10 at 7 Block without spending Block")
	guard_first.play_card(MAGE, _find_copy(guard_first, &"arcane_reversal"), data.enemy_id)
	_check(guard_first.enemy_hp == data.enemy_max_hp - 24 and guard_first.players[MAGE].block == 1,
		"Shieldstrike leaves the Block available for Arcane Reversal")
	var reversal_first := CombatState.new(data, data.shuffle_seed, [MAGE])
	reversal_first.play_card(MAGE, _find_copy(reversal_first, &"arcane_guard"), &"")
	reversal_first.play_card(MAGE, _find_copy(reversal_first, &"arcane_reversal"), data.enemy_id)
	reversal_first.play_card(MAGE, _find_copy(reversal_first, &"shieldstrike"), data.enemy_id)
	_check(reversal_first.enemy_hp == data.enemy_max_hp - 22 and reversal_first.players[MAGE].block == 1,
		"Shieldstrike sees less Block and deals less damage when Arcane Reversal goes first")
	var prepared := CombatState.new(data, data.shuffle_seed, [MAGE])
	prepared.play_card(MAGE, _find_copy(prepared, &"battle_preparation"), &"")
	prepared.play_card(MAGE, _find_copy(prepared, &"arcane_reversal"), data.enemy_id)
	_check(prepared.enemy_hp == data.enemy_max_hp - 17 and prepared.players[MAGE].block == 1 and
		prepared.players[MAGE].next_attack_bonus == 0 and prepared.players[MAGE].mana == 1,
		"Battle Preparation adds one bonus to Arcane Reversal alongside its Block-spend damage")


func _test_shared_phase() -> void:
	var data := _fixture([BLOCK, STRIKE])
	data.player_max_hp = 9
	var state := CombatState.new(data, data.shuffle_seed, [MAGE, ALLY])
	var mage := state.players[MAGE]
	var ally := state.players[ALLY]
	_check(mage.hand[0] != ally.hand[0], "each player has distinct card copies")
	_check(not state.play_card(MAGE, ally.hand[0], &""), "reject another player's copy")
	var unplayed := _find_copy(state, &"basic_strike")
	var ally_opening_hand := ally.hand.duplicate()
	state.play_card(MAGE, _find_copy(state, &"basic_block"), &"")
	state.end_turn(MAGE)
	_check(mage.mana == 0 and mage.block == 5 and state.round_number == 1 and ally.hp == 9,
		"ending one player expires their Mana and waits with their Block intact")
	_check(mage.hand.is_empty() and mage.discard_pile.has(unplayed) and ally.hand == ally_opening_hand and
		ally.discard_pile.is_empty(), "turn end must clear only the owner's unplayed cards before the enemy phase")
	_check(not state.end_turn(MAGE) and ally.mana == 3, "an ended actor cannot end twice or spend ally Mana")
	state.end_turn(ALLY)
	_check(mage.hp == 5 and ally.hp == 0, "one enemy attack hits all living players against independent Block")
	_check(state.phase == CombatState.Phase.PLAYER and state.round_number == 2,
		"one surviving player keeps the fight active")
	_check(not state.end_turn(ALLY), "a defeated actor cannot submit a turn command")
	state.end_turn(MAGE)
	_check(state.phase == CombatState.Phase.DEFEAT and state.round_number == 2,
		"the phase no longer waits on defeated players and ends when all are down")


func _test_terminal_states() -> void:
	var data := _fixture([STRIKE, BLOCK])
	data.enemy_max_hp = 4
	data.player_max_hp = 4
	var win := CombatState.new(data, data.shuffle_seed, [MAGE])
	win.play_card(MAGE, _find_copy(win, &"basic_strike"), data.enemy_id)
	_check(win.phase == CombatState.Phase.VICTORY and win.enemy_hp == 0 and win.players[MAGE].hp == 4,
		"lethal damage gives immediate victory without an enemy action")
	_check(not win.play_card(MAGE, _find_copy(win, &"basic_block"), &"") and not win.end_turn(MAGE),
		"victory rejects further actions")
	var loss := CombatState.new(data, data.shuffle_seed, [MAGE])
	loss.end_turn(MAGE)
	_check(loss.phase == CombatState.Phase.DEFEAT and loss.players[MAGE].hp == 0 and loss.round_number == 1,
		"lethal enemy damage gives defeat without starting a new round")
	_check(not loss.end_turn(MAGE) and loss.action_history.size() == 1, "defeat rejects further turns")


func _test_replay() -> void:
	var first := CombatState.new(ENCOUNTER, ENCOUNTER.shuffle_seed, [MAGE])
	var second := CombatState.new(ENCOUNTER, ENCOUNTER.shuffle_seed, [MAGE])
	var player := first.players[MAGE]
	_check(player.hand == second.players[MAGE].hand, "same seed produces matching opening copies")
	first.play_card(MAGE, _find_copy(first, &"battle_preparation"), &"")
	first.play_card(MAGE, _find_copy(first, &"arcane_reversal"), ENCOUNTER.enemy_id)
	for _turn in 3:
		first.end_turn(MAGE)
	_check("Arcane Reversal spent 6 Block for +6 damage." in first.combat_log and
		"Battle Mage shuffled their discard pile into the draw pile." in first.combat_log,
		"the replay sequence exercises the conditional spend and a seeded reshuffle")
	for action in first.action_history:
		if action[&"command"] == &"play_card":
			second.play_card(action[&"player"], action[&"copy"], action[&"target"])
		else:
			second.end_turn(action[&"player"])
	_check(first.action_history == second.action_history and first.combat_log == second.combat_log,
		"seed and accepted commands replay identical actions and combat log")
	var replayed := second.players[MAGE]
	_check(player.hand == replayed.hand and player.draw_pile == replayed.draw_pile and
		player.discard_pile == replayed.discard_pile and player.hp == replayed.hp and
		first.enemy_hp == second.enemy_hp, "the replay reproduces piles and damage")


func _fixture(deck: Array[CardData]) -> EncounterData:
	var data: EncounterData = ENCOUNTER.duplicate()
	data.test_deck = deck
	return data


func _find_copy(state: CombatState, card_id: StringName, player_id: StringName = MAGE) -> int:
	for copy in state.players[player_id].hand:
		if state.card_data(copy).id == card_id:
			return copy
	return -1


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
