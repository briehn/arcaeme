extends SceneTree

const Pool = preload("res://scripts/run/battle_mage_pool_playtest.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const RunState = preload("res://scripts/run/run_state.gd")
const CoopRunState = preload("res://scripts/run/coop_run_state.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const CardData = preload("res://scripts/combat/card_data.gd")
const Arcana = preload("res://scripts/run/major_arcana.gd")
const ROUTE = preload("res://resources/prototype/multi_enemy_run.tres")
const TWIN = preload("res://resources/prototype/cards/pool_expansion/twin_sigil.tres")
const KEYSTONE = preload("res://resources/prototype/cards/pool_expansion/keystone_cut.tres")
const OATH = preload("res://resources/prototype/cards/pool_expansion/spellsteel_oath.tres")
const AEGIS = preload("res://resources/prototype/cards/pool_expansion/aegis_temper.tres")
const MIRROR = preload("res://resources/prototype/cards/pool_expansion/mirror_lunge.tres")
const WARD = preload("res://resources/prototype/cards/pool_expansion/glimmer_ward.tres")
const PAGE = preload("res://resources/prototype/cards/pool_expansion/tacticians_page.tres")
const SURVEY = preload("res://resources/prototype/cards/pool_expansion/rune_survey.tres")
const FOCUS = preload("res://resources/prototype/cards/pool_expansion/kindled_focus.tres")
const EMBER = preload("res://resources/prototype/cards/pool_expansion/ember_script.tres")
const BRAND = preload("res://resources/prototype/cards/pool_expansion/searing_brand.tres")
const SHATTER = preload("res://resources/prototype/cards/pool_expansion/shatterguard.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const PRISM = preload("res://resources/prototype/cards/expansion/prism_wall.tres")
const PREP = preload("res://resources/prototype/cards/battle_preparation.tres")
const FIRST := &"slime_1"
const SECOND := &"slime_2"
const MAGE := RunState.PLAYER_ID
const CLASS := RunData.BATTLE_MAGE

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_spellblade()
	_test_defense()
	_test_cycling()
	_test_risk()
	_test_offer_catalog()
	_test_reward_carryover()
	_test_portal_pool()
	print("Battle Mage pool: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _test_spellblade() -> void:
	var combat := _combat([PREP, KEYSTONE, TWIN])
	var actor := combat.players[MAGE]
	actor.strength = 2
	combat.enemy_state(SECOND).hp = 40
	_play(combat, PREP)
	_play(combat, KEYSTONE, SECOND)
	_check(combat.enemy_state(SECOND).hp == 31 and actor.next_attack_bonus == 3,
		"Keystone consumes prior prep, then prepares the next Attack")
	_play(combat, TWIN, SECOND)
	_check(combat.enemy_state(SECOND).hp == 18 and combat.enemy_state(FIRST).hp == 18
		and actor.next_attack_bonus == 0 and actor.mana == 0,
		"Twin uses Strength twice and new preparation once, all on the selected target")

	combat = _combat([TWIN], Arcana.TOWER)
	combat.enemy_state(FIRST).hp = 6
	_play(combat, TWIN, FIRST)
	_check(combat.enemy_state(FIRST).hp == 0 and combat.enemy_state(SECOND).hp == 22
		and combat.players[MAGE].burning == 3, "a lethal first Tower hit never redirects its second hit")
	combat = _combat([TWIN], Arcana.TOWER)
	_play(combat, TWIN, FIRST)
	_check(combat.enemy_state(FIRST).hp == 7 and combat.players[MAGE].burning == 3,
		"Tower boosts only the first Twin hit")

	combat = _combat([OATH, STRIKE], Arcana.STRENGTH)
	actor = combat.players[MAGE]
	actor.arcana_attacks = 2
	_play(combat, OATH, SECOND)
	_check(combat.enemy_state(SECOND).hp == 15 and actor.strength == 2 and actor.mana == 1,
		"Oath deals unboosted damage before its own Strength and third-Attack Arcana")
	_play(combat, STRIKE, SECOND)
	_check(combat.enemy_state(SECOND).hp == 7 and actor.strength == 2,
		"both Strength gains apply to later attacks")


func _test_defense() -> void:
	var combat := _combat([AEGIS, WARD])
	var actor := combat.players[MAGE]
	actor.dexterity = 2
	_play(combat, AEGIS)
	_play(combat, WARD)
	_check(actor.dexterity == 3 and actor.block == 13 and actor.mana == 1,
		"Aegis grants Dexterity first and the zero-cost Ward benefits from it")
	combat.end_turn(MAGE)
	_check(actor.block == 0 and actor.dexterity == 3,
		"fresh round clears Block but keeps the encounter-local Dexterity")

	combat = _combat([WARD, MIRROR], Arcana.JUSTICE)
	actor = combat.players[MAGE]
	actor.dexterity = 1
	_play(combat, MIRROR, FIRST)
	_check(actor.block == 6 and combat.enemy_state(FIRST).hp == 10 and not actor.arcana_used,
		"Mirror's own Block scales its hit, while Justice requires prior Block")
	combat = _combat([WARD, MIRROR], Arcana.JUSTICE)
	actor = combat.players[MAGE]
	actor.block = 3
	_play(combat, WARD)
	_play(combat, MIRROR, SECOND)
	_check(actor.block == 14 and combat.enemy_state(SECOND).hp == 12 and actor.arcana_used,
		"prior Block enables Justice; its later grant adds no damage to Mirror")

	for starting_block in [0, 4, 7, 8]:
		combat = _combat([SHATTER])
		actor = combat.players[MAGE]
		actor.block = starting_block
		actor.strength = 1
		combat.enemy_state(SECOND).hp = 60
		combat.enemy_state(SECOND).block = 7
		_play(combat, SHATTER, SECOND)
		@warning_ignore("integer_division")
		var spend: int = starting_block / 4 * 4
		_check(combat.enemy_state(SECOND).hp == 55 - spend and combat.enemy_state(SECOND).block == 0
			and actor.block == starting_block - spend and combat.enemy_state(FIRST).hp == 18,
			"Shatterguard resolves two Strength hits and each spends against its own threshold")
	combat = _combat([SHATTER])
	combat.players[MAGE].block = 8
	combat.enemy_state(FIRST).hp = 5
	_play(combat, SHATTER, FIRST)
	_check(combat.players[MAGE].block == 0 and combat.enemy_state(SECOND).hp == 22,
		"Shatterguard's second effect still spends when its first hit is lethal, without retargeting")


func _test_cycling() -> void:
	var combat := _combat([PAGE, TWIN, STRIKE])
	var actor := combat.players[MAGE]
	actor.hand.assign([0])
	actor.draw_pile.assign([2, 1])
	_play(combat, PAGE)
	_check(actor.hand == [1] and actor.next_attack_bonus == 4 and actor.mana == 2,
		"Page discovers an Attack and primes its first hit")
	_play(combat, TWIN, FIRST)
	_check(combat.enemy_state(FIRST).hp == 8, "Page boosts only the first Twin hit")

	combat = _combat([SURVEY, WARD, STRIKE, TWIN], Arcana.MAGICIAN)
	actor = combat.players[MAGE]
	actor.hand.assign([0])
	actor.draw_pile.assign([1])
	actor.discard_pile.assign([2, 3])
	actor.dexterity = 1
	_play(combat, SURVEY)
	_check(actor.hand.size() == 3 and 0 not in actor.hand and actor.discard_pile == [0]
		and actor.block == 6 and actor.mana == 1, "Survey crosses a reshuffle before entering discard")
	_play(combat, STRIKE, SECOND)
	_check(actor.arcana_used and actor.mana == 0 and 0 in actor.hand and 2 not in actor.hand,
		"Magician draws a previously discarded card, without redrawing the triggering Attack")
	_play(combat, WARD)
	_check(actor.block == 9 and actor.mana == 0 and not combat.can_play_card(MAGE, 0, &""),
		"zero Mana allows Ward but prevents repeated cycling")
	combat.end_turn(MAGE)
	_check(actor.hand.size() == 4 and actor.discard_pile.is_empty() and actor.mana == 3,
		"normal phase closure discards unplayed cards and starts a fresh draw")


func _test_risk() -> void:
	var combat := _combat([FOCUS, TWIN, PRISM])
	var actor := combat.players[MAGE]
	_play(combat, FOCUS)
	_check(actor.strength == 1 and actor.dexterity == 1 and actor.block == 0 and actor.mana == 1,
		"Focus spends 2 Mana on two encounter-local stats with no immediate Block")
	_play(combat, TWIN, FIRST)
	_check(combat.enemy_state(FIRST).hp == 10, "Focus adds Strength to both Twin hits")
	combat.end_turn(MAGE)
	_play(combat, PRISM)
	_check(actor.block == 18, "Focus adds Dexterity to both Prism Wall grants")

	combat = _combat([EMBER, BRAND, STRIKE], Arcana.MAGICIAN)
	actor = combat.players[MAGE]
	actor.hand.assign([0, 1])
	actor.draw_pile.assign([2])
	actor.strength = 2
	_check(not combat.can_play_card(MAGE, 0, &""), "Ember is a targeted non-Attack")
	_play(combat, EMBER, SECOND)
	_check(actor.hand == [1, 2] and not actor.arcana_used and combat.enemy_state(SECOND).burning == 1,
		"Ember cycles and applies Burning without consuming the Attack half of Magician")
	_play(combat, BRAND, SECOND)
	_check(combat.enemy_state(SECOND).hp == 15 and combat.enemy_state(SECOND).burning == 5
		and combat.enemy_state(FIRST).burning == 0 and actor.arcana_used,
		"Brand uses Strength on its direct hit and stacks Burning only on that enemy")
	combat.end_turn(MAGE)
	_check(actor.hp == 29 and combat.enemy_state(SECOND).hp == 10 and combat.enemy_state(SECOND).burning == 3,
		"the marked enemy acts before its Burning tick and the existing decay applies")
	combat = _combat([BRAND])
	combat.enemy_state(FIRST).hp = 5
	_play(combat, BRAND, FIRST)
	_check(combat.enemy_state(FIRST).burning == 0 and combat.enemy_state(SECOND).burning == 0,
		"Brand applies no Burning when its own hit defeats the target")


func _test_offer_catalog() -> void:
	var expanded := Pool.with_expanded_rewards(ROUTE)
	var catalog := expanded.eligible_rewards(CLASS)
	_check(Pool.NEW_CARDS.size() == 12 and catalog.size() == 21
		and expanded.starting_deck == ROUTE.starting_deck, "12 new rewards extend the opted-in catalog to 21")
	_check(ROUTE.reward_offer_count == 0 and ROUTE.reward_candidates.size() == 3
		and ROUTE.reward_offers(CLASS, 2, 3) == ROUTE.reward_candidates
		and expanded.opening_encounters == ROUTE.opening_encounters and expanded.boss_encounter == ROUTE.boss_encounter,
		"legacy rewards, starter deck, and encounters remain intact")
	for card in Pool.NEW_CARDS:
		_check(card in catalog and card.approval_status == "Provisional" and card.owner_class_id == CLASS
			and not card.description().is_empty() and card not in ROUTE.starting_deck,
			"%s is a provisional Battle Mage reward and outside the starter deck" % card.display_name)
	var universal: CardData = TWIN.duplicate()
	universal.owner_class_id = &"universal"
	expanded.reward_candidates.append_array([TWIN, universal])
	_check(expanded.eligible_rewards(CLASS) == catalog and expanded.reward_offers(&"other_class", 1, 0).is_empty(),
		"deduplication and class filtering apply before selection")
	var seen := {}
	for index in 32:
		var offers := expanded.reward_offers(CLASS, index % 3 + 1, index % 4, 93705 + index)
		_check(offers.size() == 3 and offers[0] != offers[1] and offers[0] != offers[2] and offers[1] != offers[2]
			and offers == expanded.reward_offers(CLASS, index % 3 + 1, index % 4, 93705 + index),
			"same seed and context produce three unique offers")
		for card in offers:
			seen[card.id] = true
	_check(seen.size() == catalog.size(), "seeded sampling can offer every eligible card")


func _test_reward_carryover() -> void:
	var data := Pool.with_expanded_rewards(ROUTE)
	var solo := RunState.new(data)
	var replay := RunState.new(data)
	for run in [solo, replay]:
		run.choose_opening(data.opening_encounters[0].enemy_id)
		run.active_combat.players[MAGE].hp = 27
		run.active_combat.phase = CombatState.Phase.VICTORY
		run.finish_combat(run.active_combat)
	var reward := solo.reward_options()[0]
	_check(solo.reward_options() == replay.reward_options()
		and not solo.take_reward(_unoffered(data, solo.reward_options())),
		"solo replays the exact offers and rejects an unoffered class reward")
	for run in [solo, replay]:
		_check(run.take_reward(reward.id) and run.start_next_encounter(), "each solo run drafts and advances")
	_check(solo.deck_cards().back() == reward and solo.active_combat.players[MAGE].hp == 27
		and solo.active_combat.players[MAGE].hand == replay.active_combat.players[MAGE].hand,
		"drafted reward, remaining HP, and seeded next draw carry over")

	var roster: Array[StringName] = [&"One", &"Two", &"Three", &"Four"]
	var party := CoopRunState.new(data, roster, 87012)
	var opposite := CoopRunState.new(data, roster, 87012)
	for run in [party, opposite]:
		run.active_combat.phase = CombatState.Phase.VICTORY
		run.observe_combat_result()
	var view := party.view_fields(roster[0])
	_check(view.reward_options == opposite.view_fields(roster[0]).reward_options
		and view.reward_options != party.view_fields(roster[1]).reward_options
		and not view.has("offer_seed"), "co-op private seed replays the receiving seat's offers")
	var offered := data.reward_offers(CLASS, 1, 0, 87012)
	_check(not party.submit_reward(roster[0], _unoffered(data, offered)), "co-op rejects unoffered class rewards")
	for seat in roster.size():
		var id: StringName = offered[0].id if seat == 0 else &""
		_check(party.submit_reward(roster[seat], id), "each seat can take or skip once")
		if seat == 0:
			_check(party.view_fields(roster[0]).reward_options.is_empty()
				and not party.submit_reward(roster[0], id), "an accepted take hides its own offers and cannot repeat")
	for seat in range(roster.size() - 1, -1, -1):
		opposite.submit_reward(roster[seat], offered[0].id if seat == 0 else &"")
	for seat in roster.size():
		_check(party.deck_cards(roster[seat]).size() == data.starting_deck.size() + int(seat == 0)
			and party.active_combat.players[roster[seat]].hand == opposite.active_combat.players[roster[seat]].hand,
			"the drafted card is private and next combat is independent of submission order")


func _test_portal_pool() -> void:
	var data := Pool.with_expanded_rewards(ROUTE)
	data.portal_enabled = true
	data.major_arcana_enabled = true
	var run := RunState.new(data)
	var arcana_id := StringName(run.arcana_options()[0].id)
	_check(run.submit_arcana(arcana_id) and run.choose_opening(data.opening_encounters[0].enemy_id),
		"the Portal and Arcana options compose with expanded rewards")
	run.active_combat.phase = CombatState.Phase.VICTORY
	run.finish_combat(run.active_combat)
	var reward := run.reward_options()[0]
	_check(run.take_reward(reward.id) and run.stage == RunState.Stage.PORTAL and run.reward_options().is_empty(),
		"taking a reward still opens the portal gate and closes reward input")
	var option := run.portal_options()[0]
	_check(option.type == "Normal Encounter" and run.submit_portal(StringName(option.id))
		and run.active_combat.players[MAGE].arcana_id == arcana_id and run.deck_cards().back() == reward,
		"the portal hides its destination and carries the drafted card and Arcana into fresh combat")
	run.active_combat.phase = CombatState.Phase.VICTORY
	run.finish_combat(run.active_combat)
	_check(run.reward_options() == data.reward_offers(CLASS, 2, 0) and run.skip_reward()
		and run.stage == RunState.Stage.PORTAL, "the next portal leg offers a fresh encounter-keyed draft")


func _unoffered(data: RunData, offers: Array[CardData]) -> StringName:
	for card in data.eligible_rewards(CLASS):
		if card not in offers:
			return card.id
	return &""


func _combat(deck: Array[CardData], arcana: StringName = &"") -> CombatState:
	var data = ROUTE.opening_encounters[0].duplicate()
	data.test_deck = deck
	return CombatState.new(data, ROUTE.run_seed, [MAGE], -1, {}, {}, {MAGE: arcana})


func _play(combat: CombatState, card: CardData, target: StringName = &"") -> void:
	for copy_id in combat.players[MAGE].hand:
		if combat.card_data(copy_id) == card:
			_check(combat.play_card(MAGE, copy_id, target), "%s plays legally" % card.display_name)
			return
	_check(false, "%s must be in hand" % card.display_name)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr(message)
