extends SceneTree

const CardData = preload("res://scripts/combat/card_data.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const RunState = preload("res://scripts/run/run_state.gd")
const Pacing = preload("res://scripts/run/pacing_experiment.gd")
const Expansion = preload("res://scripts/run/card_expansion_playtest.gd")
const DEFAULT = preload("res://resources/prototype/battle_mage_encounter.tres")
const ROUTE = preload("res://resources/prototype/enemy_variety_run.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const BLOCK = preload("res://resources/prototype/cards/basic_block.tres")
const GUARD = preload("res://resources/prototype/cards/arcane_guard.tres")
const PREPARATION = preload("res://resources/prototype/cards/battle_preparation.tres")
const SHIELDSTRIKE = preload("res://resources/prototype/cards/shieldstrike.tres")
const REVERSAL = preload("res://resources/prototype/cards/arcane_reversal.tres")
const SALVO = preload("res://resources/prototype/cards/expansion/astral_salvo.tres")
const CUT = preload("res://resources/prototype/cards/expansion/rune_cut.tres")
const WARDED = preload("res://resources/prototype/cards/expansion/warded_strike.tres")
const WALL = preload("res://resources/prototype/cards/expansion/prism_wall.tres")
const STUDY = preload("res://resources/prototype/cards/expansion/arcane_study.tres")
const FORGE = preload("res://resources/prototype/cards/expansion/spellforge.tres")
const CANDIDATES: Array[CardData] = [SALVO, CUT, WARDED, WALL, STUDY, FORGE]
const CANDIDATE_IDS := [&"astral_salvo", &"rune_cut", &"warded_strike", &"prism_wall", &"arcane_study", &"spellforge"]
const HOST := &"Battle Mage 1"
const ALLY := &"Battle Mage 2"
const ENEMY := &"expansion_test_enemy"
const SEED := 104775

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_catalog_and_fixtures()
	_test_salvo()
	_test_cut()
	_test_warded_strike()
	_test_prism_wall()
	_test_arcane_study()
	_test_study_reveals_a_tactical_choice()
	_test_spellforge_and_periodic_damage()
	_test_run_reset()
	print("Card expansion: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _test_catalog_and_fixtures() -> void:
	var costs := [2, 1, 1, 2, 1, 1]
	for index in CANDIDATES.size():
		var card := CANDIDATES[index]
		_check(card.id == CANDIDATE_IDS[index] and card.mana_cost == costs[index]
			and card.owner_class_id == RunData.BATTLE_MAGE and card.approval_status.to_lower().contains("provisional"),
			"%s has its expected identity, cost, ownership, and provisional label" % card.display_name)
		_check(card.is_attack == (index < 3) and card.targets_enemy() == card.is_attack and not card.description().is_empty(),
			"%s has the correct targeting and printed rules" % card.display_name)

	var original_deck := DEFAULT.test_deck.duplicate()
	var new_encounter := Expansion.with_expansion_deck(DEFAULT)
	var new_run := Expansion.with_expansion_run(ROUTE)
	var expected: Array[CardData] = [STRIKE, STRIKE, BLOCK, GUARD, PREPARATION]
	expected.append_array(CANDIDATES)
	_check(new_encounter != DEFAULT and DEFAULT.test_deck == original_deck, "standalone expansion does not mutate its source")
	_check(new_encounter.test_deck == expected and new_encounter.enemy_id == DEFAULT.enemy_id
		and new_encounter.enemy_max_hp == DEFAULT.enemy_max_hp and new_encounter.shuffle_seed == DEFAULT.shuffle_seed,
		"standalone expansion replaces only its playtest deck")
	_check(new_run != ROUTE and new_run.starting_deck == expected and new_run.starting_deck.size() == ROUTE.starting_deck.size(),
		"the optional run deck uses all six candidates and stays the same size as the control")
	_check(new_run.opening_encounters == ROUTE.opening_encounters and new_run.boss_encounter == ROUTE.boss_encounter
		and new_run.run_seed == ROUTE.run_seed and new_run.player_max_hp == ROUTE.player_max_hp,
		"expansion leaves encounters, the seed, and starting HP intact")
	_check(new_run.eligible_rewards(RunData.BATTLE_MAGE) == ROUTE.eligible_rewards(RunData.BATTLE_MAGE)
		and new_run.eligible_rewards(&"universal").is_empty(),
		"the incumbent class-eligible reward pool remains unchanged")
	for card in CANDIDATES:
		_check(card not in ROUTE.starting_deck and card not in ROUTE.reward_candidates,
			"%s does not enter the existing deck or reward pool" % card.display_name)
	var combined := Pacing.make_run(ROUTE, Pacing.VariantKind.COMBINED, 4)
	var combined_expansion := Expansion.with_expansion_run(combined)
	_check(combined_expansion.opening_encounters == combined.opening_encounters
		and combined_expansion.boss_encounter == combined.boss_encounter
		and combined_expansion.starting_deck == expected,
		"the expansion deck can compose with the existing opt-in pacing fixture")


func _test_salvo() -> void:
	_check(SALVO.description() == "Deal 7 damage twice.", "Astral Salvo uses its approved wording")
	var standalone := _combat([SALVO])
	_play(standalone, SALVO)
	_check(standalone.enemy_hp == 86 and standalone.players[HOST].mana == 1
		and standalone.combat_log.count("Expansion Test Enemy took 7 damage.") == 2,
		"Astral Salvo lands two independent seven-damage hits for two Mana")
	var prepared := _combat([SALVO, PREPARATION])
	prepared.players[HOST].strength = 2
	_play(prepared, PREPARATION)
	_play(prepared, SALVO)
	_check(prepared.enemy_hp == 79 and prepared.players[HOST].next_attack_bonus == 0 and prepared.players[HOST].block == 7
		and "Expansion Test Enemy took 12 damage." in prepared.combat_log and "Expansion Test Enemy took 9 damage." in prepared.combat_log,
		"Strength applies to both hits and Battle Preparation only to the first")


func _test_cut() -> void:
	var combat := _combat([CUT, STRIKE, BLOCK], 4)
	var actor := combat.players[HOST]
	actor.hand.assign([0])
	actor.draw_pile.assign([1])
	actor.discard_pile.assign([2])
	var log_start := combat.combat_log.size()
	_play(combat, CUT)
	var play_log := combat.combat_log.slice(log_start)
	_check(combat.phase == CombatState.Phase.VICTORY and actor.mana == 2 and actor.hand == [1] and 0 in actor.discard_pile,
		"Rune Cut lands lethal four damage and still draws before discarding itself")
	_check(play_log.find("Expansion Test Enemy took 4 damage.") < play_log.find("Battle Mage 1 drew 1 card.")
		and play_log.find("Expansion Test Enemy took 4 damage.") >= 0 and "Battle Mage 1 drew 1 card." in play_log,
		"Rune Cut resolves its hit before its draw")


func _test_warded_strike() -> void:
	var standalone := _combat([WARDED])
	_play(standalone, WARDED)
	_check(standalone.enemy_hp == 97 and standalone.players[HOST].block == 4 and standalone.players[HOST].mana == 2,
		"Warded Strike independently deals three damage and grants four Block")
	var lethal := _combat([WARDED], 3)
	_play(lethal, WARDED)
	_check(lethal.phase == CombatState.Phase.VICTORY and lethal.players[HOST].block == 4,
		"Warded Strike resolves Block after a lethal hit")
	var party := _combat([WARDED, REVERSAL], 100, 8, [HOST, ALLY])
	var host := party.players[HOST]
	host.dexterity = 2
	var copy := _copy(party, HOST, WARDED)
	_check(not party.play_card(ALLY, copy, ENEMY), "an ally cannot submit a Warded Strike copy from another seat")
	_play(party, WARDED)
	_check(host.block == 6 and party.players[ALLY].block == 0 and party.players[ALLY].mana == 3,
		"Dexterity raises the caster's Warded Strike Block without donating it")
	_play(party, REVERSAL)
	_check(party.enemy_hp == 83 and host.block == 0, "Warded Strike can enable Reversal's exact six-Block branch")
	var below := _combat([WARDED, REVERSAL])
	_play(below, WARDED)
	_play(below, REVERSAL)
	_check(below.enemy_hp == 89 and below.players[HOST].block == 4,
		"below the Reversal threshold, Warded Strike's Block remains intact")


func _test_prism_wall() -> void:
	_check(WALL.description() == "Gain 8 Block twice.", "Prism Wall uses its approved wording")
	var standalone := _combat([WALL])
	_play(standalone, WALL)
	_check(standalone.players[HOST].block == 16 and standalone.players[HOST].mana == 1,
		"Prism Wall grants sixteen Block from two effects for two Mana")
	var combat := _combat([WALL, SHIELDSTRIKE])
	combat.players[HOST].dexterity = 2
	var before := combat.combat_log.size()
	_play(combat, WALL)
	_check(combat.players[HOST].block == 20 and combat.combat_log.slice(before).count("Battle Mage 1 gained 10 Block.") == 2,
		"Prism Wall applies Dexterity to each distinct Block effect")
	_play(combat, SHIELDSTRIKE)
	_check(combat.enemy_hp == 86 and combat.players[HOST].block == 20,
		"Shieldstrike reads Prism Wall Block without spending it or adding Dexterity directly")


func _test_arcane_study() -> void:
	var combat := _combat([STUDY, STRIKE, BLOCK, GUARD])
	var actor := combat.players[HOST]
	actor.hand.assign([0])
	actor.draw_pile.assign([1])
	actor.discard_pile.assign([2, 3])
	_play(combat, STUDY)
	_check(actor.hand.size() == 2 and 1 in actor.hand and 0 not in actor.hand and actor.discard_pile == [0]
		and actor.draw_pile.size() == 1 and actor.mana == 2,
		"Arcane Study draws across a reshuffle without drawing itself during its effect")
	_check(combat.end_turn(HOST) and actor.hand.size() == 4 and actor.discard_pile.is_empty(),
		"unplayed cards also discard and are available to the following turn's normal draw")


func _test_study_reveals_a_tactical_choice() -> void:
	for card in [SALVO, WALL]:
		var combat := _combat([STUDY, SALVO, WALL], 14, 14)
		var actor := combat.players[HOST]
		actor.hand.assign([0])
		actor.draw_pile.assign([1, 2])
		_check(not combat.can_play_card(HOST, 1, ENEMY) and not combat.can_play_card(HOST, 2, &""),
			"neither answer is available before drawing")
		_play(combat, STUDY)
		_check(combat.can_play_card(HOST, 1, ENEMY) and combat.can_play_card(HOST, 2, &""),
			"drawing opens two legal plays with the remaining two Mana")
		_play(combat, card)
		if card == SALVO:
			_check(combat.phase == CombatState.Phase.VICTORY and actor.hp == 36, "Salvo ends the fight")
		else:
			_check(combat.end_turn(HOST) and actor.hp == 36 and combat.enemy_hp == 14,
				"Prism Wall covers the telegraphed hit and leaves the fight active")


func _test_spellforge_and_periodic_damage() -> void:
	var forge := _combat([FORGE, STRIKE])
	_play(forge, FORGE)
	_check(forge.players[HOST].strength == 1 and forge.players[HOST].block == 4 and forge.players[HOST].mana == 2,
		"Spellforge gives immediate defense and one encounter-local Strength")
	_play(forge, STRIKE)
	_check(forge.enemy_hp == 93, "Spellforge immediately increases a subsequent single hit")
	var combat := _combat([FORGE])
	var actor := combat.players[HOST]
	actor.dexterity = 2
	actor.poison = 2
	actor.burning = 3
	combat.enemy_poison = 4
	combat.enemy_burning = 5
	_play(combat, FORGE)
	_check(actor.block == 6 and actor.strength == 1, "Spellforge's Block qualifies for Dexterity")
	_check(combat.end_turn(HOST) and combat.enemy_hp == 91 and combat.enemy_poison == 3 and combat.enemy_burning == 3
		and actor.hp == 29 and actor.poison == 1 and actor.burning == 2 and actor.strength == 1,
		"Poison and Burning still tick separately through Block and ignore both Strength and Dexterity")


func _test_run_reset() -> void:
	var data: RunData = Expansion.with_expansion_run(ROUTE).duplicate()
	var opening: EncounterData = data.opening_encounters[0].duplicate()
	opening.enemy_max_hp = 3
	data.opening_encounters = [opening]
	data.starting_deck = [FORGE, WARDED]
	var run := RunState.new(data)
	_check(run.choose_opening(opening.enemy_id), "test run begins the expansion encounter")
	var combat := run.active_combat
	var player := RunState.PLAYER_ID
	_check(combat.end_turn(player) and combat.players[player].hp == 29, "the Goblin hit causes HP to carry")
	_play(combat, FORGE, player, opening.enemy_id)
	_play(combat, WARDED, player, opening.enemy_id)
	_check(combat.phase == CombatState.Phase.VICTORY and combat.players[player].strength == 1
		and combat.players[player].block == 8, "the opening closes with active expansion effects")
	_check(run.finish_combat(combat) and run.take_reward(&"shieldstrike") and run.start_boss(),
		"the incumbent personal reward advances the expansion run")
	var next := run.active_combat.players[player]
	_check(next.hp == 29 and next.strength == 0 and next.dexterity == 0 and next.block == 0 and next.mana == 3
		and run.deck_cards() == [FORGE, WARDED, SHIELDSTRIKE], "fresh combat clears modifiers and carries HP plus the private deck")


func _combat(cards: Array[CardData], hp := 100, attack := 8, seats: Array[StringName] = [HOST]) -> CombatState:
	var fixture := EncounterData.new()
	fixture.player_max_hp = 36
	fixture.enemy_id = ENEMY
	fixture.enemy_name = "Expansion Test Enemy"
	fixture.enemy_max_hp = hp
	fixture.enemy_attack = attack
	fixture.test_deck = cards
	return CombatState.new(fixture, SEED, seats)


func _copy(combat: CombatState, player: StringName, card: CardData) -> int:
	for copy in combat.players[player].hand:
		if combat.card_data(copy) == card:
			return copy
	return -1


func _play(combat: CombatState, card: CardData, player := HOST, enemy := ENEMY) -> void:
	var target := enemy if card.targets_enemy() else &""
	_check(combat.play_card(player, _copy(combat, player, card), target),
		"%s plays %s with a legal target" % [player, card.display_name])


func _check(condition: bool, context: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr(context)
