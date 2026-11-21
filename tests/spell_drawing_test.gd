extends SceneTree

const CardData = preload("res://scripts/combat/card_data.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const Matcher = preload("res://scripts/combat/rune_matcher.gd")
const Arcana = preload("res://scripts/run/major_arcana.gd")
const SETTINGS = preload("res://resources/prototype/spell_drawing_settings.tres")
const ENCOUNTER = preload("res://resources/prototype/enemies/two_slimes.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const BLOCK = preload("res://resources/prototype/cards/basic_block.tres")
const SALVO = preload("res://resources/prototype/cards/expansion/astral_salvo.tres")
const BOOSTER = preload("res://resources/prototype/cards/spell_ink_booster.tres")
const PREP = preload("res://resources/prototype/cards/battle_preparation.tres")
const MAGE := &"Mage One"
const ALLY := &"Mage Two"
const FIRST := &"slime_1"
const SECOND := &"slime_2"
const NOW := 1000

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_matching()
	_test_cast_transaction()
	_test_block_and_bypass()
	_test_booster_and_ordered_hits()
	_test_local_ownership()
	_test_encounter_outcomes()
	print("Spell drawing: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _test_matching() -> void:
	_check(SETTINGS.test_deck == [STRIKE, BLOCK, SALVO, BOOSTER, PREP], "the isolated fixture includes all three runes")
	_check(STRIKE.rune_template != BLOCK.rune_template and STRIKE.rune_template.cast_time_ms == 6500
		and BLOCK.rune_template.cast_time_ms == 6500 and SALVO.rune_template.cast_time_ms == 9500,
		"Basic Attack and Basic Block have different shared templates; the multi-stroke rune has more time")
	for card in [STRIKE, BLOCK, SALVO]:
		var guide: Array[PackedVector2Array] = card.rune_template.strokes
		_check(_score(guide, guide) == 1.0, "%s exact rune matches" % card.display_name)
		_check(is_equal_approx(_score(guide, _resampled(guide)), 1.0),
			"%s tolerates translation, scale, and dense input" % card.display_name)
		_check(_score(guide, []) == 0.0, "empty drawing fails")
	var salvo: Array[PackedVector2Array] = SALVO.rune_template.strokes
	_check(_score(salvo, [salvo[1], salvo[0]]) == 0.0
		and _score(salvo, [salvo[0]]) == 0.0, "matching requires both Salvo strokes in order")
	var reversed := STRIKE.rune_template.strokes[0].duplicate()
	reversed.reverse()
	_check(_score(STRIKE.rune_template.strokes, [reversed]) == 0.0
		and _score(STRIKE.rune_template.strokes, BLOCK.rune_template.strokes) == 0.0,
		"a backwards or unrelated rune fails")
	var tiny := PackedVector2Array([Vector2(0.1, 0.1), Vector2(0.11, 0.11)])
	var malformed := PackedVector2Array([Vector2(0, 0), Vector2(INF, 1)])
	_check(_score(STRIKE.rune_template.strokes, [tiny]) == 0.0
		and _score(STRIKE.rune_template.strokes, [malformed]) == 0.0,
		"tiny and malformed drawings fail")
	var score := _score(STRIKE.rune_template.strokes, _rough_strike())
	_check(score > 0.0 and score < SETTINGS.clean_score, "a plausible rough stroke falls inside the accepted rough tier")
	_check(SETTINGS.power_percent(0.79999, false) == 85 and SETTINGS.power_percent(0.80, false) == 100
		and SETTINGS.power_percent(1.0, true) == 120 and SETTINGS.power_percent(score, true) == 105,
		"accuracy cutoff and booster arithmetic are exact")


func _test_cast_transaction() -> void:
	var combat := _combat()
	var actor := combat.players[MAGE]
	var copy := _copy(combat, STRIKE)
	var hand := actor.hand.duplicate()
	var draw := actor.draw_pile.duplicate()
	var discard := actor.discard_pile.duplicate()
	var intent := combat.enemy_state(SECOND).intent()
	_check(combat.can_play_card(MAGE, copy, SECOND) and not combat.play_card(MAGE, copy, SECOND),
		"a playable assigned card cannot use the immediate native resolver entry point")
	_check(combat.begin_spell_cast(MAGE, copy, &"", NOW).is_empty()
		and combat.begin_spell_cast(MAGE, copy, &"wrong", NOW).is_empty()
		and combat.begin_spell_cast(&"Stranger", copy, SECOND, NOW).is_empty(), "reject absent target and wrong owner")
	var cast := combat.begin_spell_cast(MAGE, copy, SECOND, NOW)
	if not _check(not cast.is_empty(), "legal begin returns a cast"):
		return
	_check(cast.deadline_ms == 7500 and not combat.can_end_turn(MAGE)
		and combat.begin_spell_cast(MAGE, copy, FIRST, NOW).is_empty(),
		"one pending cast blocks End Turn and a replacement begin")
	_check(not combat.expire_spell_cast(MAGE, 7499) and combat.cancel_spell_cast(MAGE)
		and not combat.cancel_spell_cast(MAGE), "cancel is clean, single-use, and early expiry does not clear")
	combat.begin_spell_cast(MAGE, copy, SECOND, NOW)
	_check(combat.submit_spell_cast(MAGE, [], NOW + 1) == CombatState.CastResult.INCOMPLETE,
		"blank drawings can retry without resolving")
	combat.begin_spell_cast(MAGE, copy, SECOND, NOW)
	_check(combat.submit_spell_cast(MAGE, BLOCK.rune_template.strokes, NOW + 1) == CombatState.CastResult.MISDRAWN,
		"a different rune does not resolve the card")
	var presentation := combat.begin_spell_cast(MAGE, copy, SECOND, NOW)
	var display_stroke: PackedVector2Array = presentation.guide[0]
	display_stroke.clear()
	_check(not STRIKE.rune_template.strokes[0].is_empty() and combat.cancel_spell_cast(MAGE),
		"the drawing display cannot mutate the shared template")
	combat.begin_spell_cast(MAGE, copy, SECOND, NOW)
	_check(combat.submit_spell_cast(MAGE, cast.guide, 7500) == CombatState.CastResult.EXPIRED,
		"a drawing submitted exactly at the deadline expires")
	combat.begin_spell_cast(MAGE, copy, SECOND, NOW)
	_check(combat.expire_spell_cast(MAGE, 7501) and not combat.expire_spell_cast(MAGE, 7501),
		"deadline update expires once")
	combat.begin_spell_cast(MAGE, copy, SECOND, NOW)
	combat.enemy_state(SECOND).hp = 0
	_check(combat.submit_spell_cast(MAGE, cast.guide, NOW + 1) == CombatState.CastResult.INVALID,
		"the intended target is checked again before spending")
	combat.enemy_state(SECOND).hp = 22
	_check(actor.hand == hand and actor.draw_pile == draw and actor.discard_pile == discard and actor.mana == 3
		and combat.action_history.is_empty() and combat.enemy_state(SECOND).intent() == intent and combat.round_number == 1,
		"failures leave piles, Mana, history, round, and intent intact")

	actor.strength = 2
	actor.next_attack_bonus = 3
	combat.begin_spell_cast(MAGE, copy, SECOND, NOW)
	_check(combat.submit_spell_cast(MAGE, _rough_strike(), NOW + 1) == CombatState.CastResult.SUCCESS,
		"a rough accepted rune resolves")
	_check(actor.mana == 2 and copy not in actor.hand and actor.discard_pile.count(copy) == 1
		and combat.action_history.size() == 1 and combat.action_history[0].spell_power_percent == 85
		and combat.enemy_state(SECOND).hp == 12 and combat.enemy_state(FIRST).hp == 18
		and actor.next_attack_bonus == 0, "only base damage scales; spend happens once and remains bound to target")
	_check(combat.submit_spell_cast(MAGE, cast.guide, NOW + 2) == CombatState.CastResult.NO_CAST and actor.mana == 2,
		"duplicate submission cannot spend Mana or replay the card")


func _test_block_and_bypass() -> void:
	var combat := _combat()
	var actor := combat.players[MAGE]
	var copy := _copy(combat, BLOCK)
	actor.dexterity = 2
	_check(combat.begin_spell_cast(MAGE, copy, FIRST, NOW).is_empty()
		and not combat.begin_spell_cast(MAGE, copy, &"", NOW).is_empty(), "self-only Block rejects an enemy target")
	_check(combat.submit_spell_cast(MAGE, BLOCK.rune_template.strokes, NOW + 1) == CombatState.CastResult.SUCCESS
		and actor.block == 7 and actor.mana == 2, "clean Block gets full base power plus Dexterity")
	combat = _combat()
	actor = combat.players[MAGE]
	actor.dexterity = 2
	combat.begin_spell_cast(MAGE, _copy(combat, BLOCK), &"", NOW)
	var rough_block: Array[PackedVector2Array] = [
		PackedVector2Array([Vector2(0.25, 0.28), Vector2(0.56, 0.69), Vector2(0.75, 0.28)]),
	]
	_check(combat.submit_spell_cast(MAGE, rough_block, NOW + 1) == CombatState.CastResult.SUCCESS
		and actor.block == 6 and combat.action_history.back().spell_power_percent == 85,
		"a rough cast scales the Block grant before adding full Dexterity")

	var bypass := _combat([STRIKE, BLOCK, BOOSTER], [MAGE], {}, true, true)
	_check(bypass.begin_spell_cast(MAGE, _copy(bypass, STRIKE), FIRST, NOW).is_empty()
		and bypass.play_card(MAGE, _copy(bypass, BLOCK), &"") and bypass.players[MAGE].block == 5,
		"test bypass uses exact unpenalized power without opening a cast")
	_check(bypass.play_card(MAGE, _copy(bypass, BOOSTER), &"")
		and bypass.play_card(MAGE, _copy(bypass, STRIKE), FIRST) and bypass.enemy_hp == 11
		and bypass.players[MAGE].spell_booster_stroke.is_empty(), "bypass still exercises one full-power booster resolution")
	var legacy := _combat([STRIKE, BLOCK, SALVO], [MAGE], {}, false)
	_check(legacy.play_card(MAGE, _copy(legacy, STRIKE), FIRST)
		and legacy.play_card(MAGE, _copy(legacy, SALVO), SECOND)
		and legacy.enemy_hp == 12 and legacy.enemy_state(SECOND).hp == 8
		and not legacy.action_history.back().has(&"spell_power_percent"), "disabled combat keeps the original resolver and history")


func _test_booster_and_ordered_hits() -> void:
	var combat := _combat([BOOSTER, BOOSTER, SALVO, PREP, STRIKE], [MAGE], {MAGE: Arcana.TOWER})
	var actor := combat.players[MAGE]
	_check(combat.play_card(MAGE, _copy(combat, BOOSTER), &"") and actor.mana == 2
		and not actor.spell_booster_stroke.is_empty(), "the Booster spends one Mana and resolves instantly")
	_check(not combat.play_card(MAGE, _copy(combat, BOOSTER), &"") and actor.mana == 2,
		"another Booster cannot stack or pay while primed")
	_check(combat.play_card(MAGE, _copy(combat, PREP), &"") and not actor.spell_booster_stroke.is_empty()
		and combat.end_turn(MAGE) and not actor.spell_booster_stroke.is_empty(),
		"an unassigned card and round closure preserve the one pending booster")
	var salvo := _copy(combat, SALVO)
	var cast := combat.begin_spell_cast(MAGE, salvo, SECOND, NOW)
	if not _check(not cast.is_empty(), "ready Booster allows Salvo to start"):
		return
	_check(cast.boosted and cast.guide.size() == 3 and cast.guide[2] == BOOSTER.spell_booster_stroke,
		"the third stroke appears in the cast guide")
	_check(combat.submit_spell_cast(MAGE, SALVO.rune_template.strokes, NOW + 1) == CombatState.CastResult.INCOMPLETE
		and not actor.spell_booster_stroke.is_empty() and actor.mana == 3, "missing booster stroke leaves it primed")
	combat.begin_spell_cast(MAGE, salvo, SECOND, NOW)
	_check(combat.cancel_spell_cast(MAGE) and not actor.spell_booster_stroke.is_empty(), "canceling a boosted cast retains it")
	combat.begin_spell_cast(MAGE, salvo, SECOND, NOW)
	_check(combat.submit_spell_cast(MAGE, cast.guide, cast.deadline_ms) == CombatState.CastResult.EXPIRED
		and not actor.spell_booster_stroke.is_empty(), "expiry retains the Booster")
	actor.strength = 2
	actor.next_attack_bonus = 3
	combat.enemy_state(SECOND).hp = 50
	combat.enemy_state(SECOND).block = 4
	combat.begin_spell_cast(MAGE, salvo, SECOND, NOW)
	_check(combat.submit_spell_cast(MAGE, cast.guide, NOW + 1) == CombatState.CastResult.SUCCESS
		and actor.mana == 1 and actor.discard_pile.count(salvo) == 1 and actor.spell_booster_stroke.is_empty(),
		"successful boosted cast consumes the exact card and Booster once")
	_check(combat.enemy_state(SECOND).hp == 26 and combat.enemy_state(FIRST).hp == 18
		and actor.burning == 3 and actor.next_attack_bonus == 0,
		"two rounded base hits preserve Strength, preparation, mitigation, Tower, and target order")
	var strike := _copy(combat, STRIKE)
	cast = combat.begin_spell_cast(MAGE, strike, SECOND, NOW)
	if _check(not cast.is_empty(), "a follow-up card can cast immediately"):
		_check(cast.guide.size() == 1 and not cast.boosted, "the consumable stroke is absent from the following rune")
		combat.cancel_spell_cast(MAGE)
	var fresh := _combat()
	_check(BOOSTER.spell_booster_stroke.size() == 2 and fresh.play_card(MAGE, _copy(fresh, BOOSTER), &""),
		"consumption never clears the shared card resource")


func _test_local_ownership() -> void:
	var combat := _combat([STRIKE, BLOCK, BOOSTER], [MAGE, ALLY])
	var copy := _copy(combat, STRIKE)
	_check(combat.begin_spell_cast(ALLY, copy, FIRST, NOW).is_empty(), "one seat cannot start another seat's card")
	combat.play_card(MAGE, _copy(combat, BOOSTER), &"")
	var cast := combat.begin_spell_cast(MAGE, copy, FIRST, NOW)
	if not _check(not cast.is_empty(), "local caster has an active rune"):
		return
	_check(combat.submit_spell_cast(ALLY, cast.guide, NOW + 1) == CombatState.CastResult.NO_CAST
		and not combat.cancel_spell_cast(ALLY) and not combat.end_turn(ALLY)
		and combat.players[ALLY].spell_booster_stroke.is_empty(),
		"another local seat cannot complete or clear the cast or receive its boost")
	_check(combat.cancel_spell_cast(MAGE) and combat.end_turn(MAGE) and combat.can_undo_ready(MAGE)
		and combat.undo_ready(MAGE) and combat.round_number == 1, "normal Ready and Undo Ready resume after cancellation")


func _test_encounter_outcomes() -> void:
	var combat := _combat()
	combat.enemy_state(FIRST).hp = 0
	combat.enemy_state(SECOND).hp = 6
	combat.begin_spell_cast(MAGE, _copy(combat, STRIKE), SECOND, NOW)
	_check(combat.submit_spell_cast(MAGE, STRIKE.rune_template.strokes, NOW + 1) == CombatState.CastResult.SUCCESS
		and combat.phase == CombatState.Phase.VICTORY and not combat.can_end_turn(MAGE),
		"a lethal drawn card immediately follows the usual victory path")
	combat = _combat()
	combat.players[MAGE].hp = 1
	combat.begin_spell_cast(MAGE, _copy(combat, BLOCK), &"", NOW)
	_check(combat.expire_spell_cast(MAGE, 7500) and combat.end_turn(MAGE)
		and combat.phase == CombatState.Phase.DEFEAT and combat.players[MAGE].block == 0,
		"ending the turn after an expired Block follows the usual defeat path")


func _combat(deck: Array[CardData] = SETTINGS.test_deck, seats: Array[StringName] = [MAGE],
		arcana: Dictionary[StringName, StringName] = {}, enabled := true, bypass := false) -> CombatState:
	var fixture: EncounterData = ENCOUNTER.duplicate()
	fixture.test_deck = deck
	return CombatState.new(fixture, fixture.shuffle_seed, seats, -1, {}, {}, arcana,
		SETTINGS if enabled else null, bypass)


func _copy(combat: CombatState, card: CardData) -> int:
	for copy in combat.players[MAGE].hand:
		if combat.card_data(copy) == card:
			return copy
	return -1


func _rough_strike() -> Array[PackedVector2Array]:
	return [PackedVector2Array([Vector2(0.28, 0.20), Vector2(0.62, 0.56), Vector2(0.29, 0.70)])]


func _resampled(strokes: Array[PackedVector2Array]) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	for stroke in strokes:
		var points := PackedVector2Array([stroke[0] * 0.67 + Vector2(0.10, 0.25)])
		for index in range(1, stroke.size()):
			for step in range(1, 9):
				var point := stroke[index - 1].lerp(stroke[index], step / 8.0)
				points.append(point * 0.67 + Vector2(0.10, 0.25))
		result.append(points)
	return result


func _score(guide: Array[PackedVector2Array], drawing: Array[PackedVector2Array]) -> float:
	return Matcher.recognize(guide, drawing, SETTINGS.minimum_extent, SETTINGS.recognition_tolerance)


func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		printerr(message)
	return condition
