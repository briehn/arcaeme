extends SceneTree

const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const DATA = preload("res://resources/prototype/local_coop_encounter.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const BLOCK = preload("res://resources/prototype/cards/basic_block.tres")
const GUARD = preload("res://resources/prototype/cards/arcane_guard.tres")
const ONE := &"Battle Mage 1"
const TWO := &"Battle Mage 2"
const THREE := &"Battle Mage 3"
const FOUR := &"Battle Mage 4"

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_shared_phase_and_replay()
	_test_either_player_can_act_first()
	_test_personal_reshuffle()
	_test_party_defeat()
	_test_survivor_and_recovery()
	print("Co-op combat state: %d checks, %d failures." % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _test_shared_phase_and_replay() -> void:
	var state := CombatState.new(DATA, DATA.shuffle_seed, [ONE, TWO])
	var one := state.players[ONE]
	var two := state.players[TWO]
	_check(one.hp == 25 and two.hp == 25 and one.max_hp == 25 and two.max_hp == 25 and
		one.mana == 3 and two.mana == 3 and one.hand.size() == 5 and two.hand.size() == 5,
		"both players begin the same phase with full personal resources and five cards")
	_check(not state.play_card(ONE, two.hand[0], DATA.enemy_id) and state.action_history.is_empty(),
		"reject another player's card copy without accepting a command")
	_play(state, TWO, &"basic_strike", DATA.enemy_id)
	_check(state.enemy_hp == 36 and two.mana == 2 and one.mana == 3, "player two can act first and deals damage immediately")
	var two_hand := two.hand.duplicate()
	var two_draw := two.draw_pile.duplicate()
	var two_discard := two.discard_pile.duplicate()
	_play(state, ONE, &"arcane_guard", &"")
	_check(one.block == 7 and one.hand.size() == 5 and one.draw_pile.size() == 11 and two.block == 0 and
		two.hand == two_hand and two.draw_pile == two_draw and two.discard_pile == two_discard,
		"Arcane Guard changes only its owner's Block and card piles")
	_play(state, ONE, &"battle_preparation", &"")
	_check(one.block == 14 and one.next_attack_bonus == 3 and two.next_attack_bonus == 0,
		"Battle Preparation buffs only its owner")
	_play(state, TWO, &"arcane_reversal", DATA.enemy_id)
	_check(state.enemy_hp == 28 and one.next_attack_bonus == 3 and one.block == 14 and two.block == 0,
		"another player's Arcane Reversal neither spends the owner's Block nor consumes preparation")
	_play(state, ONE, &"shieldstrike", DATA.enemy_id)
	_check(state.enemy_hp == 13 and one.next_attack_bonus == 0 and one.block == 14,
		"the owner's Shieldstrike applies both of its own bonuses")
	_play(state, TWO, &"basic_block", &"")
	_check(state.end_turn(TWO), "player two can end before player one")
	_check(two.ended_turn and two.hand.is_empty() and two.discard_pile.size() == 5 and
		not one.ended_turn and one.hand.size() == 3 and state.round_number == 1 and one.hp == 25 and two.hp == 25,
		"the first end-turn only clears that player's hand and waits")
	_check(not state.can_end_turn(TWO) and not state.end_turn(TWO), "reject a repeated end-turn")
	_check(state.end_turn(ONE), "the other player can end the shared phase")
	_check(one.hp == 25 and two.hp == 17 and state.round_number == 2 and
		"Battle Mage 1 blocked 13 and lost 0 HP." in state.combat_log and
		"Battle Mage 2 blocked 5 and lost 8 HP." in state.combat_log, "the full enemy attack uses each player's own Block")
	_check(one.mana == 3 and two.mana == 3 and one.hand.size() == 5 and two.hand.size() == 5 and
		one.block == 0 and two.block == 0 and not one.ended_turn and not two.ended_turn,
		"the next personal turns refresh independently")
	var accepted_players: Array[StringName] = []
	var replay := CombatState.new(DATA, DATA.shuffle_seed, [ONE, TWO])
	for action in state.action_history:
		accepted_players.append(action[&"player"])
		if action[&"command"] == &"play_card":
			replay.play_card(action[&"player"], action[&"copy"], action[&"target"])
		else:
			replay.end_turn(action[&"player"])
	_check(accepted_players == [TWO, ONE, ONE, TWO, ONE, TWO, TWO, ONE], "record commands in the order accepted")
	_check(replay.action_history == state.action_history and replay.combat_log == state.combat_log and
		replay.players[ONE].hand == one.hand and replay.players[TWO].hand == two.hand and replay.enemy_hp == state.enemy_hp,
		"the same seed and accepted commands replay both hands and outcomes")


func _test_either_player_can_act_first() -> void:
	var data := _small_fixture()
	for first_id in [ONE, TWO]:
		var state := CombatState.new(data, data.shuffle_seed, [ONE, TWO])
		var second_id := TWO if first_id == ONE else ONE
		_play(state, first_id, &"basic_strike", data.enemy_id)
		_check(state.phase == CombatState.Phase.VICTORY and state.players[first_id].mana == 2 and
			state.players[second_id].mana == 3, "either player's first strike can immediately win the fight")
		_check(not state.play_card(second_id, _find_copy(state, second_id, &"basic_strike"), data.enemy_id) and
			state.action_history.size() == 1, "reject later actions once victory is settled")


func _test_personal_reshuffle() -> void:
	var data := _small_fixture()
	data.test_deck = [BLOCK, GUARD]
	var state := CombatState.new(data, data.shuffle_seed, [ONE, TWO])
	var own_block := _find_copy(state, ONE, &"basic_block")
	var ally_hand := state.players[TWO].hand.duplicate()
	_play(state, ONE, &"basic_block", &"")
	_play(state, ONE, &"arcane_guard", &"")
	_check(state.players[ONE].hand == [own_block] and state.players[ONE].discard_pile.size() == 1 and
		state.players[TWO].hand == ally_hand and state.players[TWO].discard_pile.is_empty() and
		"Battle Mage 1 shuffled their discard pile into the draw pile." in state.combat_log,
		"Arcane Guard reshuffles only the owner's discard and cannot redraw its own resolving copy")


func _test_party_defeat() -> void:
	var data := _small_fixture()
	var state := CombatState.new(data, data.shuffle_seed, [ONE, TWO])
	_check(state.end_turn(ONE) and state.phase == CombatState.Phase.PLAYER, "player one can also end first")
	_check(state.end_turn(TWO) and state.phase == CombatState.Phase.DEFEAT, "the enemy defeats the full party")
	_check(state.players[ONE].hp == 0 and state.players[TWO].hp == 0 and
		not state.players[ONE].recovered_after_victory and not state.players[TWO].recovered_after_victory and
		state.round_number == 1 and not state.can_end_turn(TWO), "defeat gives neither player recovery or a new turn")


func _test_survivor_and_recovery() -> void:
	var data := _small_fixture()
	var state := CombatState.new(data, data.shuffle_seed, [ONE, TWO, THREE, FOUR])
	# Simulate players arriving with different max and current HP. The local fixture itself uses equal max HP.
	state.players[ONE].hp = 3
	state.players[TWO].max_hp = 13
	state.players[THREE].max_hp = 1
	state.players[THREE].hp = 1
	_play(state, ONE, &"basic_block", &"")
	for player_id in [FOUR, TWO, ONE, THREE]:
		_check(state.end_turn(player_id), "accept end-turn for every living participant")
	_check(state.phase == CombatState.Phase.PLAYER and state.round_number == 2 and state.players[ONE].hp == 3 and
		state.players[TWO].hp == 0 and state.players[THREE].hp == 0 and state.players[FOUR].hp == 0,
		"the attack hits all four and one survivor keeps the encounter active")
	_check(not state.end_turn(TWO) and not state.play_card(THREE, 0, data.enemy_id) and
		state.players[FOUR].mana == 0 and state.players[FOUR].hand.is_empty(),
		"defeated players cannot act or receive a new personal turn")
	_play(state, ONE, &"basic_block", &"")
	_check(state.end_turn(ONE) and state.round_number == 3 and state.players[TWO].hp == 0 and
		state.combat_log.count("Battle Mage 2 blocked 0 and lost 5 HP.") == 1,
		"defeated players neither block the next phase nor take the next hit")
	_play(state, ONE, &"basic_strike", data.enemy_id)
	_check(state.phase == CombatState.Phase.VICTORY and state.players[ONE].hp == 3 and
		not state.players[ONE].recovered_after_victory, "victory preserves the survivor's current HP")
	_check(state.players[TWO].hp == 4 and state.players[THREE].hp == 1 and state.players[FOUR].hp == 2 and
		state.players[TWO].recovered_after_victory and state.players[THREE].recovered_after_victory and
		state.players[FOUR].recovered_after_victory, "recover each defeated ally to a rounded-up quarter of their own max HP")
	_check("Battle Mage 2 recovered to 4/13 HP after victory." in state.combat_log and
		not state.can_end_turn(TWO) and state.players[TWO].hand.is_empty(), "recovery is logged outside the playable phase")


func _small_fixture() -> EncounterData:
	var data: EncounterData = DATA.duplicate()
	data.player_max_hp = 5
	data.enemy_max_hp = 6
	data.enemy_attack = 5
	data.test_deck = [BLOCK, STRIKE]
	return data


func _find_copy(state: CombatState, player_id: StringName, card_id: StringName) -> int:
	for copy_id in state.players[player_id].hand:
		if state.card_data(copy_id).id == card_id:
			return copy_id
	return -1


func _play(state: CombatState, player_id: StringName, card_id: StringName, target: StringName) -> void:
	_check(state.play_card(player_id, _find_copy(state, player_id, card_id), target), "%s plays %s" % [player_id, card_id])


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
