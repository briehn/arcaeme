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
	_check(STRIKE.rune_template != BLOCK.rune_template and STRIKE.rune_template.cast_time_ms == 10000
		and BLOCK.rune_template.cast_time_ms == 10000 and SALVO.rune_template.cast_time_ms == 14000,
		"Basic Attack and Basic Block have different shared templates; the multi-stroke rune has more time")
	for card in [STRIKE, BLOCK, SALVO]:
		var guide: Array[PackedVector2Array] = card.rune_template.strokes
		_check(_score(guide, guide) == 1.0, "%s exact rune matches" % card.display_name)
		var reversed := _reversed_strokes(guide)
		_check(is_equal_approx(_score(guide, reversed), 1.0), "%s matches with all strokes reversed" % card.display_name)
		_check(is_equal_approx(_score(guide, _resampled(guide)), 1.0),
			"%s tolerates translation, scale, and dense input" % card.display_name)
		_check(_score(guide, []) == 0.0, "empty drawing fails")
	var salvo: Array[PackedVector2Array] = SALVO.rune_template.strokes
	var outline := _recognize(salvo, [salvo[0]])
	_check(is_equal_approx(_score(salvo, [salvo[1], salvo[0]]), 1.0) and outline != null and not outline.complete,
		"swapped strokes match while the recognizable outline alone is incomplete")
	var off_corner := salvo[0][1].lerp(salvo[0][2], 0.47)
	var shifted := PackedVector2Array([off_corner, salvo[0][2], salvo[0][3], salvo[0][0], salvo[0][1], off_corner])
	var shifted_match := _recognize(salvo, [_reverse(salvo[1]), _reverse(shifted)])
	_check(shifted_match != null and shifted_match.complete and shifted_match.score >= SETTINGS.excellent_score,
		"a reversed Salvo outline started along an edge matches at excellent power")
	var partial := _recognize(STRIKE.rune_template.strokes, [_reverse(_partial_strike()[0])])
	_check(partial != null and not partial.complete, "a recognizable partial stroke can be traced backwards")
	var short_line := PackedVector2Array([salvo[1][0].lerp(salvo[1][1], 0.65), salvo[1][0]])
	var partial_salvo := _recognize(salvo, [short_line, _reverse(salvo[0])])
	_check(partial_salvo != null and SETTINGS.quality(partial_salvo.score, partial_salvo.complete) == "Faint",
		"a shortened line before the outline remains a faint Salvo")
	_check(_score(salvo, [salvo[0], _reverse(shifted)]) == 0.0
		and _score(salvo, [salvo[1], _reverse(salvo[1])]) == 0.0
		and _score(salvo, [salvo[1]]) == 0.0, "repeated components and a lone line do not replace Salvo structure")
	_check(_score(salvo, BLOCK.rune_template.strokes) == 0.0, "a single Block corner cannot stand in for a partial loop")
	var augmented := salvo.duplicate()
	augmented.append(SALVO.rune_template.booster_stroke)
	for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]:
		var shuffled: Array[PackedVector2Array] = [_reverse(augmented[order[0]]),
			augmented[order[1]], _reverse(augmented[order[2]])]
		_check(is_equal_approx(_score(augmented, shuffled), 1.0),
			"boosted Salvo has the same score in component order %s" % str(order))
	var arm := PackedVector2Array([STRIKE.rune_template.strokes[0][0], STRIKE.rune_template.strokes[0][1]])
	_check(_score(STRIKE.rune_template.strokes, [arm]) == 0.0,
		"a long straight swipe cannot replace a rune corner")
	var slight_curve := PackedVector2Array([Vector2(0.31, 0.20), Vector2(0.45, 0.34),
		Vector2(0.59, 0.44), Vector2(0.63, 0.51), Vector2(0.48, 0.62), Vector2(0.32, 0.72)])
	var curve := _recognize(STRIKE.rune_template.strokes, [slight_curve])
	_check(curve != null and curve.complete and curve.score >= SETTINGS.acceptable_score,
		"a realistic curved and off-endpoint trace retains at least ordinary power")
	var scribble := PackedVector2Array([Vector2(0.28, 0.20), Vector2(0.75, 0.2), Vector2(0.28, 0.40),
		Vector2(0.75, 0.50), Vector2(0.28, 0.70), Vector2(0.75, 0.80)])
	_check(_score(STRIKE.rune_template.strokes, [scribble]) == 0.0, "a large unrelated zigzag cannot cast")
	_check(_score(STRIKE.rune_template.strokes, BLOCK.rune_template.strokes) == 0.0,
		"an unrelated rune still fails")
	var tiny := PackedVector2Array([Vector2(0.1, 0.1), Vector2(0.11, 0.11)])
	var malformed := PackedVector2Array([Vector2(0, 0), Vector2(INF, 1)])
	_check(_score(STRIKE.rune_template.strokes, [tiny]) == 0.0
		and _score(STRIKE.rune_template.strokes, [malformed]) == 0.0,
		"tiny and malformed drawings fail")
	_check(SETTINGS.quality(0.39999, true) == "Faint" and SETTINGS.quality(0.40, true) == "Acceptable"
		and SETTINGS.quality(0.81999, true) == "Acceptable" and SETTINGS.quality(0.82, true) == "Excellent"
		and SETTINGS.quality(1.0, false) == "Faint", "accuracy cutoffs and partial cap are exact")
	_check(SETTINGS.power_percent("Faint", false) == 75 and SETTINGS.power_percent("Acceptable", false) == 100
		and SETTINGS.power_percent("Excellent", false) == 110 and SETTINGS.power_percent("Faint", true) == 95
		and SETTINGS.power_percent("Acceptable", true) == 120 and SETTINGS.power_percent("Excellent", true) == 130,
		"all three quality tiers and Booster arithmetic are exact")
	for card in [STRIKE, BLOCK, SALVO]:
		var rune = card.rune_template
		var connected := false
		for stroke: PackedVector2Array in rune.strokes:
			for index in range(1, stroke.size()):
				connected = connected or Geometry2D.segment_intersects_segment(stroke[index - 1], stroke[index],
					rune.booster_stroke[0], rune.booster_stroke[1]) != null
				for endpoint: Vector2 in rune.booster_stroke:
					connected = connected or Geometry2D.get_closest_point_to_segment(
						endpoint, stroke[index - 1], stroke[index]).distance_to(endpoint) < 0.0001
		_check(connected, "%s augmentation connects to its guide" % card.display_name)
		var combat := _combat()
		combat.play_card(MAGE, _copy(combat, BOOSTER), &"")
		var cast := _start(combat, _copy(combat, card), FIRST if card.is_attack else &"")
		var shuffled := _reversed_strokes(cast.guide)
		shuffled.reverse()
		_check(not cast.is_empty() and cast.guide[-1] == rune.booster_stroke
			and combat.submit_spell_cast(MAGE, shuffled, NOW + 1) == CombatState.CastResult.SUCCESS
			and combat.action_history.back().spell_power_percent == 130
			and not combat.players[MAGE].spell_booster_primed,
			"%s resolves with its augmentation first and consumes its Booster" % card.display_name)


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
	_check(_start(combat, copy, &"").is_empty()
		and _start(combat, copy, &"wrong").is_empty()
		and combat.begin_spell_cast(&"Stranger", copy, SECOND).is_empty(), "reject absent target and wrong owner")
	var cast := combat.begin_spell_cast(MAGE, copy, SECOND)
	if not _check(not cast.is_empty(), "legal begin returns a cast"):
		return
	_check(combat.submit_spell_cast(MAGE, cast.guide, NOW) == CombatState.CastResult.NO_CAST
		and combat.expire_spell_cast(MAGE, cast.guide, NOW + 50000) == CombatState.CastResult.NO_CAST
		and not combat.can_end_turn(MAGE) and combat.begin_spell_cast(MAGE, copy, FIRST).is_empty(),
		"the pending cast holds combat, but cannot submit or expire before the surface is ready")
	_check(combat.start_spell_cast_clock(MAGE, NOW + 100) == NOW + 10100
		and combat.start_spell_cast_clock(MAGE, NOW + 101) == -1
		and combat.expire_spell_cast(MAGE, cast.guide, NOW + 10099) == CombatState.CastResult.NO_CAST
		and combat.cancel_spell_cast(MAGE) and not combat.cancel_spell_cast(MAGE),
		"the full window starts once at readiness and cancellation is single-use")
	_start(combat, copy, SECOND)
	_check(combat.submit_spell_cast(MAGE, [], NOW + 1) == CombatState.CastResult.MISDRAWN,
		"blank drawings never resolve")
	_start(combat, copy, SECOND)
	_check(combat.submit_spell_cast(MAGE, BLOCK.rune_template.strokes, NOW + 1) == CombatState.CastResult.MISDRAWN,
		"a different rune does not resolve the card")
	var presentation := _start(combat, copy, SECOND)
	var display_stroke: PackedVector2Array = presentation.guide[0]
	display_stroke.clear()
	_check(not STRIKE.rune_template.strokes[0].is_empty() and combat.cancel_spell_cast(MAGE),
		"the drawing display cannot mutate the shared template")
	_start(combat, copy, SECOND)
	_check(combat.expire_spell_cast(MAGE, [], NOW + 10000) == CombatState.CastResult.EXPIRED
		and combat.expire_spell_cast(MAGE, cast.guide, NOW + 10001) == CombatState.CastResult.NO_CAST,
		"blank expiry clears the cast exactly once")
	_start(combat, copy, SECOND)
	combat.enemy_state(SECOND).hp = 0
	_check(combat.submit_spell_cast(MAGE, cast.guide, NOW + 1) == CombatState.CastResult.INVALID,
		"the intended target is checked again before spending")
	combat.enemy_state(SECOND).hp = 22
	_check(actor.hand == hand and actor.draw_pile == draw and actor.discard_pile == discard and actor.mana == 3
		and combat.action_history.is_empty() and combat.enemy_state(SECOND).intent() == intent and combat.round_number == 1,
		"failures leave piles, Mana, history, round, and intent intact")

	actor.strength = 2
	actor.next_attack_bonus = 3
	_start(combat, copy, SECOND)
	_check(combat.expire_spell_cast(MAGE, _partial_strike(), NOW + 10000) == CombatState.CastResult.SUCCESS,
		"a recognizable partial drawing resolves at the deadline")
	_check(actor.mana == 2 and copy not in actor.hand and actor.discard_pile.count(copy) == 1
		and combat.action_history.size() == 1 and combat.action_history[0].spell_power_percent == 75
		and combat.enemy_state(SECOND).hp == 12 and combat.enemy_state(FIRST).hp == 18
		and actor.next_attack_bonus == 0, "only base damage scales; spend happens once and remains bound to target")
	_check(combat.submit_spell_cast(MAGE, cast.guide, NOW + 2) == CombatState.CastResult.NO_CAST and actor.mana == 2,
		"duplicate submission cannot spend Mana or replay the card")
	combat = _combat()
	_start(combat, _copy(combat, STRIKE), FIRST)
	var ordinary: Array[PackedVector2Array] = [PackedVector2Array([Vector2(0.33, 0.18),
		Vector2(0.50, 0.34), Vector2(0.58, 0.43), Vector2(0.62, 0.56), Vector2(0.48, 0.66), Vector2(0.32, 0.75)])]
	_check(combat.submit_spell_cast(MAGE, ordinary, NOW + 1) == CombatState.CastResult.SUCCESS
		and combat.action_history.back().spell_power_percent == 100 and combat.enemy_hp == 12,
		"an imperfect but acceptable Strike resolves at 100% without a retry")


func _test_block_and_bypass() -> void:
	var combat := _combat()
	var actor := combat.players[MAGE]
	var copy := _copy(combat, BLOCK)
	actor.dexterity = 2
	_check(_start(combat, copy, FIRST).is_empty()
		and not _start(combat, copy, &"").is_empty(), "self-only Block rejects an enemy target")
	_check(combat.submit_spell_cast(MAGE, BLOCK.rune_template.strokes, NOW + 1) == CombatState.CastResult.SUCCESS
		and actor.block == 8 and actor.mana == 2, "excellent Block rounds base power before adding Dexterity")
	combat = _combat()
	actor = combat.players[MAGE]
	actor.dexterity = 2
	_start(combat, _copy(combat, BLOCK), &"")
	var rough_block: Array[PackedVector2Array] = [
		PackedVector2Array([Vector2(0.25, 0.28), Vector2(0.50, 0.69), Vector2(0.6425, 0.4563)]),
	]
	_check(combat.submit_spell_cast(MAGE, rough_block, NOW + 1) == CombatState.CastResult.SUCCESS
		and actor.block == 6 and combat.action_history.back().spell_power_percent == 75,
		"a rough cast scales the Block grant before adding full Dexterity")

	var bypass := _combat([STRIKE, BLOCK, BOOSTER], [MAGE], {}, true, true)
	_check(bypass.begin_spell_cast(MAGE, _copy(bypass, STRIKE), FIRST).is_empty()
		and bypass.play_card(MAGE, _copy(bypass, BLOCK), &"") and bypass.players[MAGE].block == 5,
		"test bypass uses exact unpenalized power without opening a cast")
	_check(bypass.play_card(MAGE, _copy(bypass, BOOSTER), &"")
		and bypass.play_card(MAGE, _copy(bypass, STRIKE), FIRST) and bypass.enemy_hp == 11
		and not bypass.players[MAGE].spell_booster_primed, "bypass still exercises one full-power booster resolution")
	var legacy := _combat([STRIKE, BLOCK, SALVO], [MAGE], {}, false)
	_check(legacy.play_card(MAGE, _copy(legacy, STRIKE), FIRST)
		and legacy.play_card(MAGE, _copy(legacy, SALVO), SECOND)
		and legacy.enemy_hp == 12 and legacy.enemy_state(SECOND).hp == 8
		and not legacy.action_history.back().has(&"spell_power_percent"), "disabled combat keeps the original resolver and history")


func _test_booster_and_ordered_hits() -> void:
	var combat := _combat([BOOSTER, BOOSTER, SALVO, PREP, STRIKE], [MAGE], {MAGE: Arcana.TOWER})
	var actor := combat.players[MAGE]
	_check(combat.play_card(MAGE, _copy(combat, BOOSTER), &"") and actor.mana == 2
		and actor.spell_booster_primed, "the Booster spends one Mana and resolves instantly")
	_check(not combat.play_card(MAGE, _copy(combat, BOOSTER), &"") and actor.mana == 2,
		"another Booster cannot stack or pay while primed")
	_check(combat.play_card(MAGE, _copy(combat, PREP), &"") and actor.spell_booster_primed
		and combat.end_turn(MAGE) and actor.spell_booster_primed,
		"an unassigned card and round closure preserve the one pending booster")
	var salvo := _copy(combat, SALVO)
	var cast := _start(combat, salvo, SECOND)
	if not _check(not cast.is_empty(), "ready Booster allows Salvo to start"):
		return
	_check(cast.boosted and cast.guide.size() == 3 and cast.guide[2] == SALVO.rune_template.booster_stroke,
		"the third stroke appears in the cast guide")
	_check(combat.cancel_spell_cast(MAGE) and actor.spell_booster_primed, "canceling a boosted cast retains it")
	_start(combat, salvo, SECOND)
	_check(combat.expire_spell_cast(MAGE, [], cast.deadline_ms) == CombatState.CastResult.EXPIRED
		and actor.spell_booster_primed, "expiry retains the Booster")
	_start(combat, salvo, SECOND)
	_check(combat.submit_spell_cast(MAGE, BLOCK.rune_template.strokes, NOW + 1) == CombatState.CastResult.MISDRAWN
		and actor.spell_booster_primed and actor.mana == 3, "an unrecognized attempt preserves the Booster and Mana")
	_start(combat, salvo, SECOND)
	_check(combat.submit_spell_cast(MAGE, [cast.guide[0], cast.guide[1], _reverse(cast.guide[0])], NOW + 1)
		== CombatState.CastResult.MISDRAWN and actor.spell_booster_primed and actor.mana == 3,
		"the failed-augmentation fallback cannot discard a duplicate to salvage a cast")
	actor.strength = 2
	actor.next_attack_bonus = 3
	combat.enemy_state(SECOND).hp = 50
	combat.enemy_state(SECOND).block = 4
	_start(combat, salvo, SECOND)
	_check(combat.submit_spell_cast(MAGE, cast.guide, NOW + 1) == CombatState.CastResult.SUCCESS
		and actor.mana == 1 and actor.discard_pile.count(salvo) == 1 and not actor.spell_booster_primed,
		"successful boosted cast consumes the exact card and Booster once")
	_check(combat.enemy_state(SECOND).hp == 24 and combat.enemy_state(FIRST).hp == 18
		and actor.burning == 3 and actor.next_attack_bonus == 0,
		"two rounded base hits preserve Strength, preparation, mitigation, Tower, and target order")
	var strike := _copy(combat, STRIKE)
	cast = _start(combat, strike, SECOND)
	if _check(not cast.is_empty(), "a follow-up card can cast immediately"):
		_check(cast.guide.size() == 1 and not cast.boosted, "the consumable stroke is absent from the following rune")
		combat.cancel_spell_cast(MAGE)
	var fresh := _combat()
	_check(BOOSTER.is_spell_booster and SALVO.rune_template.booster_stroke.size() == 2 and fresh.play_card(MAGE, _copy(fresh, BOOSTER), &""),
		"consumption never clears the shared card resource")
	var base_only := _start(fresh, _copy(fresh, SALVO), SECOND)
	_check(base_only.boosted and fresh.submit_spell_cast(MAGE, SALVO.rune_template.strokes, NOW + 1)
		== CombatState.CastResult.SUCCESS and not fresh.players[MAGE].spell_booster_primed
		and fresh.players[MAGE].mana == 0 and fresh.action_history.back().spell_power_percent == 75,
		"a recognizable base rune consumes the Booster without applying its bonus")
	fresh = _combat()
	fresh.play_card(MAGE, _copy(fresh, BOOSTER), &"")
	var attempted := _start(fresh, _copy(fresh, SALVO), SECOND)
	var strokes: Array[PackedVector2Array] = SALVO.rune_template.strokes.duplicate()
	strokes.push_front(PackedVector2Array([Vector2(0.50, 0.19), Vector2(0.50, 0.21)]))
	_check(fresh.expire_spell_cast(MAGE, strokes, attempted.deadline_ms) == CombatState.CastResult.SUCCESS
		and not fresh.players[MAGE].spell_booster_primed and fresh.players[MAGE].mana == 0
		and fresh.action_history.back().spell_power_percent == 75,
		"expiry resolves the base rune and consumes the charge when the first stroke is a failed augmentation")
	_check(fresh.expire_spell_cast(MAGE, attempted.guide, attempted.deadline_ms + 1) == CombatState.CastResult.NO_CAST
		and fresh.action_history.size() == 2 and fresh.players[MAGE].mana == 0,
		"duplicate resolution cannot spend again or apply the Booster bonus")


func _test_local_ownership() -> void:
	var combat := _combat([STRIKE, BLOCK, BOOSTER], [MAGE, ALLY])
	var copy := _copy(combat, STRIKE)
	_check(combat.begin_spell_cast(ALLY, copy, FIRST).is_empty(), "one seat cannot start another seat's card")
	combat.play_card(MAGE, _copy(combat, BOOSTER), &"")
	var cast := _start(combat, copy, FIRST)
	if not _check(not cast.is_empty(), "local caster has an active rune"):
		return
	_check(combat.submit_spell_cast(ALLY, cast.guide, NOW + 1) == CombatState.CastResult.NO_CAST
		and not combat.cancel_spell_cast(ALLY) and not combat.end_turn(ALLY)
		and not combat.players[ALLY].spell_booster_primed,
		"another local seat cannot complete or clear the cast or receive its boost")
	_check(combat.cancel_spell_cast(MAGE) and combat.end_turn(MAGE) and combat.can_undo_ready(MAGE)
		and combat.undo_ready(MAGE) and combat.round_number == 1, "normal Ready and Undo Ready resume after cancellation")


func _test_encounter_outcomes() -> void:
	var combat := _combat()
	combat.enemy_state(FIRST).hp = 0
	combat.enemy_state(SECOND).hp = 6
	_start(combat, _copy(combat, STRIKE), SECOND)
	_check(combat.submit_spell_cast(MAGE, STRIKE.rune_template.strokes, NOW + 1) == CombatState.CastResult.SUCCESS
		and combat.phase == CombatState.Phase.VICTORY and not combat.can_end_turn(MAGE),
		"a lethal drawn card immediately follows the usual victory path")
	combat = _combat()
	combat.players[MAGE].hp = 1
	_start(combat, _copy(combat, BLOCK), &"")
	_check(combat.expire_spell_cast(MAGE, [], NOW + 10000) == CombatState.CastResult.EXPIRED and combat.end_turn(MAGE)
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


func _start(combat: CombatState, copy: int, target: StringName) -> Dictionary:
	var cast := combat.begin_spell_cast(MAGE, copy, target)
	if not cast.is_empty():
		cast.deadline_ms = combat.start_spell_cast_clock(MAGE, NOW)
	return cast


func _partial_strike() -> Array[PackedVector2Array]:
	var guide: PackedVector2Array = STRIKE.rune_template.strokes[0]
	return [PackedVector2Array([guide[0], guide[1], guide[1].lerp(guide[2], 0.57)])]


func _reverse(stroke: PackedVector2Array) -> PackedVector2Array:
	var result := stroke.duplicate()
	result.reverse()
	return result


func _reversed_strokes(strokes: Array[PackedVector2Array]) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	for stroke in strokes:
		result.append(_reverse(stroke))
	return result


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
	var recognized := _recognize(guide, drawing)
	return recognized.score if recognized != null else 0.0


func _recognize(guide: Array[PackedVector2Array], drawing: Array[PackedVector2Array]) -> Matcher.MatchResult:
	return Matcher.recognize(guide, drawing, SETTINGS.minimum_extent, SETTINGS.recognition_tolerance,
		SETTINGS.minimum_coverage)


func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		printerr(message)
	return condition
