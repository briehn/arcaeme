extends SceneTree

const CardData = preload("res://scripts/combat/card_data.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const RunState = preload("res://scripts/run/run_state.gd")
const DATA = preload("res://resources/prototype/battle_mage_run.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const PREPARATION = preload("res://resources/prototype/cards/battle_preparation.tres")
const SHIELDSTRIKE = preload("res://resources/prototype/cards/shieldstrike.tres")
const PLAYER := RunState.PLAYER_ID

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_initialization_and_route()
	_test_reward_and_boss_victory()
	_test_skip_and_defeat()
	_test_reward_eligibility()
	_test_fresh_combat_modifiers()
	_test_seed_replay()
	print("Run state: %d checks, %d failures." % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _test_initialization_and_route() -> void:
	var run := RunState.new(DATA)
	_check(run.stage == RunState.Stage.ROUTE and run.active_combat == null and run.active_encounter == null,
		"the run starts at route choice with no combat")
	_check(run.current_hp == 36 and run.max_hp == 36 and run.run_seed == DATA.run_seed,
		"initialize full HP and the configured run seed")
	_check(run.deck_cards() == DATA.starting_deck and run.deck_cards().size() == 11,
		"initialize a copy of the configured starting deck")
	var snapshot := run.deck_cards()
	snapshot.clear()
	_check(run.deck_cards().size() == 11, "a displayed deck snapshot cannot change the run deck")
	_check(run.reward_options().is_empty() and not run.skip_reward() and not run.take_reward(&"shieldstrike") and
		not run.start_boss(), "reward and boss commands are unavailable before the opening fight")
	_check(not run.choose_opening(&"citadel_warden") and not run.choose_opening(&"unknown") and
		run.stage == RunState.Stage.ROUTE, "only a configured opening encounter is selectable")
	_check(run.choose_opening(&"rift_stalker"), "select the second opening encounter")
	_check(run.stage == RunState.Stage.OPENING_COMBAT and run.active_encounter.enemy_id == &"rift_stalker" and
		run.active_combat.enemy_hp == 18 and run.active_encounter.enemy_attack == 10, "the selected route supplies its own stats")
	_check(not run.choose_opening(&"gate_sentinel") and not run.finish_combat(run.active_combat),
		"cannot change route or report victory during combat")


func _test_reward_and_boss_victory() -> void:
	var run := RunState.new(DATA)
	_check(run.choose_opening(&"gate_sentinel"), "select the first opening encounter")
	var first := run.active_combat
	_win_gate_sentinel(run, true)
	_check(first.players[PLAYER].block == 7 and first.players[PLAYER].mana == 0,
		"the opening fight ends with combat-only resources to reset")
	_check(run.stage == RunState.Stage.REWARD and run.current_hp == 34 and run.active_combat == null,
		"opening victory leads to reward and saves the damaged HP total")
	_check(not run.finish_combat(first) and not run.start_boss(), "stale results and bypassing the reward are rejected")
	_check(run.reward_options() == DATA.reward_candidates, "offer the configured Battle Mage cards in fixed order")
	_check(not run.take_reward(&"battle_preparation") and run.deck_cards().size() == 11,
		"reject a class card that was not offered")
	_check(run.take_reward(&"shieldstrike") and run.selected_reward == SHIELDSTRIKE,
		"accept the selected Shieldstrike reward")
	_check(run.stage == RunState.Stage.BOSS_READY and run.current_hp == 34 and
		run.deck_cards() == DATA.starting_deck + [SHIELDSTRIKE], "append one reward copy and preserve deck order and HP")
	_check(DATA.starting_deck.size() == 11 and not run.take_reward(&"shieldstrike") and not run.skip_reward(),
		"a reward can settle only once and cannot edit the starting fixture")
	_check(run.start_boss(), "start the configured boss after resolving the reward")
	var boss := run.active_combat
	var player := boss.players[PLAYER]
	_check(run.stage == RunState.Stage.BOSS_COMBAT and boss != first and boss.enemy_hp == 38 and
		run.active_encounter.enemy_id == &"citadel_warden", "the boss has a separate combat with its own enemy")
	_check(player.hp == 34 and run.active_encounter.player_max_hp == 36,
		"the boss starts at current HP and keeps the real maximum HP")
	_check(boss.round_number == 1 and player.mana == 3 and player.block == 0 and
		player.next_attack_bonus == 0 and player.hand.size() == 5 and player.discard_pile.is_empty() and
		player.draw_pile.size() == 7 and boss.action_history.is_empty(), "fresh boss state deals five cards and clears combat history")
	var acquired_copy := DATA.starting_deck.size()
	_check(player.hand.has(acquired_copy) and boss.card_data(acquired_copy) == SHIELDSTRIKE,
		"the acquired copy is in the default boss opening hand")
	_check(not run.finish_combat(first) and not run.start_boss(), "a stale result cannot settle or restart the boss")
	_play(run, &"shieldstrike")
	_check(boss.enemy_hp == 30 and player.discard_pile.has(acquired_copy), "the acquired card is playable in the boss fight")
	_play(run, &"basic_strike")
	_play(run, &"basic_block")
	boss.end_turn(PLAYER)
	for _strike in 3:
		_play(run, &"basic_strike")
	boss.end_turn(PLAYER)
	_play(run, &"basic_strike")
	_check(run.finish_combat(boss) and run.stage == RunState.Stage.VICTORY and run.current_hp == 19,
		"defeating the boss wins the run and records remaining HP")
	_check(not run.choose_opening(&"gate_sentinel") and not run.start_boss() and not run.finish_combat(boss),
		"a completed run cannot reopen encounters or settle the same victory")


func _test_skip_and_defeat() -> void:
	var run := RunState.new(DATA)
	run.choose_opening(&"rift_stalker")
	var opening := run.active_combat
	for _turn in 4:
		opening.end_turn(PLAYER)
	_check(run.finish_combat(opening) and run.stage == RunState.Stage.DEFEAT and run.current_hp == 0 and
		run.reward_options().is_empty() and not run.start_boss(), "opening defeat ends the run with no reward or boss")

	var skipped := RunState.new(DATA)
	skipped.choose_opening(&"gate_sentinel")
	_win_gate_sentinel(skipped)
	_check(skipped.skip_reward() and skipped.stage == RunState.Stage.BOSS_READY and skipped.selected_reward == null and
		skipped.deck_cards() == DATA.starting_deck, "skipping advances once with the original deck")
	_check(not skipped.skip_reward() and skipped.start_boss(), "skip still leads to the boss")
	var boss := skipped.active_combat
	_check(boss.players[PLAYER].draw_pile.size() == 6, "boss draw uses the unmodified 11-card deck after skip")
	for _turn in 4:
		boss.end_turn(PLAYER)
	_check(skipped.finish_combat(boss) and skipped.stage == RunState.Stage.DEFEAT and skipped.current_hp == 0 and
		skipped.deck_cards() == DATA.starting_deck, "boss defeat ends the run and preserves the final deck for the summary")


func _test_reward_eligibility() -> void:
	var fixture: RunData = DATA.duplicate()
	var universal: CardData = SHIELDSTRIKE.duplicate()
	universal.id = &"universal_test"
	universal.owner_class_id = &"universal"
	var other_class: CardData = SHIELDSTRIKE.duplicate()
	other_class.id = &"other_class_test"
	other_class.owner_class_id = &"other_class"
	fixture.reward_candidates = [universal, other_class, STRIKE, SHIELDSTRIKE, SHIELDSTRIKE]
	var run := RunState.new(fixture)
	run.choose_opening(&"gate_sentinel")
	_win_gate_sentinel(run)
	_check(run.reward_options() == [SHIELDSTRIKE], "exclude Universal, other-class, unclassified and duplicate reward entries")
	_check(not run.take_reward(universal.id) and not run.take_reward(other_class.id) and not run.take_reward(STRIKE.id),
		"ineligible cards also fail selection by ID")
	_check(run.take_reward(SHIELDSTRIKE.id), "a valid class reward remains selectable")


func _test_fresh_combat_modifiers() -> void:
	var fixture: RunData = DATA.duplicate()
	var quick_encounter: EncounterData = DATA.opening_encounters[0].duplicate()
	quick_encounter.enemy_max_hp = 6
	fixture.opening_encounters = [quick_encounter]
	var test_damage: CardData = STRIKE.duplicate()
	test_damage.is_attack = false
	fixture.starting_deck = [PREPARATION, test_damage]
	var run := RunState.new(fixture)
	run.choose_opening(quick_encounter.enemy_id)
	var first := run.active_combat
	_play(run, &"battle_preparation")
	_play(run, &"basic_strike")
	_check(first.players[PLAYER].next_attack_bonus == 3, "a test-only non-Attack can win while preparation is still pending")
	run.finish_combat(first)
	run.skip_reward()
	run.start_boss()
	_check(run.active_combat.players[PLAYER].next_attack_bonus == 0,
		"pending preparation does not carry between encounters")


func _test_seed_replay() -> void:
	var first := RunState.new(DATA)
	var second := RunState.new(DATA)
	for run in [first, second]:
		run.choose_opening(&"gate_sentinel")
	var opening_seed := first.active_combat.shuffle_seed
	_check(opening_seed == second.active_combat.shuffle_seed and
		first.active_combat.players[PLAYER].hand == second.active_combat.players[PLAYER].hand,
		"the same run seed produces the same opening seed and hand")
	for run in [first, second]:
		_win_gate_sentinel(run)
		run.take_reward(&"shieldstrike")
		run.start_boss()
	var player := first.active_combat.players[PLAYER]
	var replayed := second.active_combat.players[PLAYER]
	_check(first.active_combat.shuffle_seed == second.active_combat.shuffle_seed and player.hand == replayed.hand and
		player.draw_pile == replayed.draw_pile and player.hp == replayed.hp and first.deck_cards() == second.deck_cards(),
		"repeat the same route, actions and reward to reproduce the boss setup")
	var fixture: RunData = DATA.duplicate()
	fixture.run_seed += 1
	var different := RunState.new(fixture)
	different.choose_opening(&"gate_sentinel")
	_check(different.active_combat.shuffle_seed != opening_seed, "changing the run seed changes the derived combat seed")


func _win_gate_sentinel(run: RunState, play_guard := false) -> void:
	_play(run, &"basic_strike")
	_play(run, &"basic_strike")
	_play(run, &"basic_block")
	run.active_combat.end_turn(PLAYER)
	if play_guard:
		_play(run, &"arcane_guard")
	_play(run, &"basic_strike")
	_play(run, &"basic_strike")
	_check(run.finish_combat(run.active_combat), "resolve the Gate Sentinel's victory")


func _play(run: RunState, card_id: StringName) -> void:
	var combat := run.active_combat
	for copy_id in combat.players[PLAYER].hand:
		var card := combat.card_data(copy_id)
		if card.id == card_id:
			var target := run.active_encounter.enemy_id if card.targets_enemy() else &""
			_check(combat.play_card(PLAYER, copy_id, target), "play %s" % card_id)
			return
	_check(false, "expected %s in hand" % card_id)


func _check(condition: bool, context: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(context)
