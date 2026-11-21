extends SceneTree

const Pool = preload("res://scripts/run/battle_mage_pool_playtest.gd")
const CardData = preload("res://scripts/combat/card_data.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const Matcher = preload("res://scripts/combat/rune_matcher.gd")
const SETTINGS = preload("res://resources/prototype/spell_drawing_settings.tres")
const ENCOUNTER = preload("res://resources/prototype/enemies/two_slimes.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const BLOCK = preload("res://resources/prototype/cards/basic_block.tres")
const BOOSTER = preload("res://resources/prototype/cards/spell_ink_booster.tres")
const SURVEY = preload("res://resources/prototype/cards/pool_expansion/rune_survey.tres")
const BRAND = preload("res://resources/prototype/cards/pool_expansion/searing_brand.tres")
const FOCUS = preload("res://resources/prototype/cards/pool_expansion/kindled_focus.tres")
const PREPARATION = preload("res://resources/prototype/cards/battle_preparation.tres")
const REVERSAL = preload("res://resources/prototype/cards/arcane_reversal.tres")
const WALL = preload("res://resources/prototype/cards/expansion/prism_wall.tres")
const SALVO = preload("res://resources/prototype/cards/expansion/astral_salvo.tres")
const MAGE := &"Battle Mage"
const TARGET := &"slime_2"
const NOW_MS := 1000

const EXPECTED_IDS := [
	&"aegis_temper", &"arcane_guard", &"arcane_reversal", &"arcane_study", &"astral_salvo",
	&"basic_block", &"basic_strike", &"battle_preparation", &"ember_script", &"glimmer_ward",
	&"keystone_cut", &"kindled_focus", &"mirror_lunge", &"prism_wall", &"rune_cut", &"rune_survey",
	&"searing_brand", &"shatterguard", &"shieldstrike", &"spellforge", &"spellsteel_oath", &"tacticians_page",
	&"twin_sigil", &"warded_strike",
]

var _checks := 0
var _failures := 0


func _initialize() -> void:
	var catalogue := Pool.catalogue()
	_test_catalogue(catalogue)
	_test_distinction(catalogue)
	_test_partial_and_inaccurate()
	_test_effect_boundaries()
	print("Battle Mage rune catalogue: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _test_catalogue(catalogue: Array[CardData]) -> void:
	var ids: Array[StringName] = []
	var names := {}
	for card in catalogue:
		ids.append(card.id)
		if not _check(not card.is_spell_booster and card.rune_template != null, "%s has a regular rune" % card.display_name):
			continue
		var rune := card.rune_template
		_check(not rune.display_name.is_empty() and not names.has(rune.display_name) and rune.cast_time_ms > 0
			and not rune.strokes.is_empty() and rune.strokes.size() <= 3,
			"%s has a distinct named and timed prototype template" % card.display_name)
		names[rune.display_name] = true
		var augmented := rune.strokes.duplicate()
		augmented.append(rune.booster_stroke)
		var valid := true
		for stroke in augmented:
			valid = valid and stroke.size() >= 2 and _length(stroke) > 0.02
			for point in stroke:
				valid = valid and point.is_finite() and Rect2(0, 0, 1, 1).grow(0.0001).has_point(point)
		_check(valid and _augmentation_connects(rune.strokes, rune.booster_stroke),
			"%s has usable normalized paths and connected augmentation" % card.display_name)
		var ordinary := _recognize(rune.strokes, _reverse_and_shuffle(rune.strokes))
		_check(ordinary != null and ordinary.complete and is_equal_approx(ordinary.score, 1.0),
			"%s matches its exact base rune even after reversing and shuffling" % card.display_name)
		var augmented_match := _recognize(augmented, _reverse_and_shuffle(augmented))
		_check(augmented_match != null and augmented_match.complete and is_equal_approx(augmented_match.score, 1.0),
			"%s recognizes its exact boosted rune with the augmentation drawn first" % card.display_name)
		_test_card_cast(card)
	_check(ids.size() == EXPECTED_IDS.size() and EXPECTED_IDS.all(func(id: StringName) -> bool: return id in ids),
		"catalogue includes exactly the existing 24 regular card IDs")
	_check(BOOSTER.is_spell_booster and BOOSTER.rune_template == null, "Spell Ink Booster is still instant")


func _test_distinction(catalogue: Array[CardData]) -> void:
	var faint_cross_matches := 0
	for intended in catalogue:
		if intended.rune_template == null:
			continue
		for other in catalogue:
			if intended == other or other.rune_template == null:
				continue
			var observed := _recognize(intended.rune_template.strokes, other.rune_template.strokes)
			if observed != null and (not observed.complete or observed.score < SETTINGS.acceptable_score):
				faint_cross_matches += 1
			_check(observed == null or not observed.complete or observed.score < SETTINGS.acceptable_score,
				"%s cannot use the full %s symbol at Acceptable or Excellent quality (score %s)" % [
					intended.display_name, other.display_name, str(observed.score) if observed != null else "none"])
	print("Catalogue directed faint overlaps: %d" % faint_cross_matches)


func _test_card_cast(card: CardData) -> void:
	var deck: Array[CardData] = [card, BOOSTER]
	var target := TARGET if card.targets_enemy() else &""
	for boosted in [false, true]:
		var state := _combat(deck)
		var actor := state.players[MAGE]
		_check(state.requires_rune(0) and not state.play_card(MAGE, 0, target),
			"%s cannot bypass the rune transaction while drawing is enabled" % card.display_name)
		if boosted:
			_check(not state.requires_rune(1) and state.play_card(MAGE, 1, &"") and actor.spell_booster_primed,
				"Booster primes instantly before %s" % card.display_name)
		var cast := state.begin_spell_cast(MAGE, 0, target)
		if not _check(not cast.is_empty() and cast.boosted == boosted
				and state.start_spell_cast_clock(MAGE, NOW_MS) == NOW_MS + card.rune_template.cast_time_ms,
				"%s opens the configured timed cast" % card.display_name):
			continue
		var before := actor.mana
		var strokes := _reverse_and_shuffle(cast.guide)
		var expected_power := 130 if boosted else 110
		_check(state.submit_spell_cast(MAGE, strokes, NOW_MS + 1) == CombatState.CastResult.SUCCESS
			and actor.mana == before - card.mana_cost and actor.discard_pile.count(0) == 1
			and 0 not in actor.hand and not actor.spell_booster_primed
			and state.action_history.back().spell_power_percent == expected_power,
			"%s resolves at %d%% with one payment and one discard" % [card.display_name, expected_power])
		var history_count := state.action_history.size()
		_check(state.submit_spell_cast(MAGE, strokes, NOW_MS + 2) == CombatState.CastResult.NO_CAST
			and actor.discard_pile.count(0) == 1 and state.action_history.size() == history_count,
			"%s ignores the same strokes after resolution" % card.display_name)


func _test_partial_and_inaccurate() -> void:
	var outline: Array[PackedVector2Array] = [SALVO.rune_template.strokes[0]]
	var partial := _recognize(SALVO.rune_template.strokes, outline)
	_check(partial != null and not partial.complete and SETTINGS.quality(partial.score, partial.complete) == "Faint",
		"recognized partial input still earns the Faint tier")
	var rough: Array[PackedVector2Array] = [PackedVector2Array([Vector2(0.33, 0.18),
		Vector2(0.50, 0.34), Vector2(0.58, 0.43), Vector2(0.62, 0.56), Vector2(0.48, 0.66), Vector2(0.32, 0.75)])]
	var acceptable := _recognize(STRIKE.rune_template.strokes, rough)
	_check(acceptable != null and SETTINGS.quality(acceptable.score, acceptable.complete) == "Acceptable",
		"a recognizable inaccurate stroke keeps the ordinary tier")


func _test_effect_boundaries() -> void:
	var state := _combat([SURVEY, BOOSTER, STRIKE, BLOCK, STRIKE])
	var actor := state.players[MAGE]
	actor.hand.assign([0, 1])
	actor.draw_pile.assign([2, 3, 4])
	actor.dexterity = 2
	_check(_cast_boosted(state) and actor.hand.size() == 3 and actor.draw_pile.is_empty() and actor.block == 9,
		"130% Rune Survey draws exactly three cards and scales Block before adding Dexterity")

	state = _combat([BRAND, BOOSTER])
	var target := state.enemy_state(TARGET)
	_check(_cast_boosted(state, TARGET) and target.hp == 15 and target.burning == 4,
		"130% Searing Brand scales only its damage and applies the original Burning count")
	_check(state.enemy_state(&"slime_1").hp == 18, "a multi-effect cast keeps its selected enemy")

	# Increase only this duplicate fixture's stat amounts so rounding would expose scaling.
	var focus: CardData = FOCUS.duplicate()
	focus.effects = FOCUS.effects.duplicate()
	for index in focus.effects.size():
		focus.effects[index] = FOCUS.effects[index].duplicate()
		focus.effects[index].amount = 4
	state = _combat([focus, BOOSTER])
	actor = state.players[MAGE]
	_check(_cast_boosted(state) and actor.strength == 4 and actor.dexterity == 4,
		"130% power does not scale discrete Strength or Dexterity gains")

	state = _combat([PREPARATION, BOOSTER])
	actor = state.players[MAGE]
	_check(_cast_boosted(state) and actor.block == 9 and actor.next_attack_bonus == 3,
		"130% Battle Preparation scales Block but keeps the flat setup bonus")

	state = _combat([WALL, BOOSTER])
	actor = state.players[MAGE]
	actor.dexterity = 2
	_check(_cast_boosted(state) and actor.block == 24,
		"Prism Wall scales each base grant without combining hits or scaling either Dexterity addition")

	state = _combat([REVERSAL, BOOSTER])
	actor = state.players[MAGE]
	actor.block = 6
	actor.strength = 2
	target = state.enemy_state(TARGET)
	_check(_cast_boosted(state, TARGET) and target.hp == 4 and actor.block == 0,
		"130% Arcane Reversal scales base damage while preserving its Block cost, flat bonus, and Strength")


func _combat(deck: Array[CardData]) -> CombatState:
	var encounter: EncounterData = ENCOUNTER.duplicate()
	encounter.test_deck = deck
	return CombatState.new(encounter, encounter.shuffle_seed, [MAGE], -1, {}, {}, {}, SETTINGS)


func _cast_boosted(state: CombatState, target := &"") -> bool:
	if not state.play_card(MAGE, 1, &""):
		return false
	var cast := state.begin_spell_cast(MAGE, 0, target)
	if cast.is_empty():
		return false
	state.start_spell_cast_clock(MAGE, NOW_MS)
	return state.submit_spell_cast(MAGE, cast.guide, NOW_MS + 1) == CombatState.CastResult.SUCCESS


func _recognize(template: Array[PackedVector2Array], drawing: Array[PackedVector2Array]) -> Matcher.MatchResult:
	return Matcher.recognize(template, drawing, SETTINGS.minimum_extent, SETTINGS.recognition_tolerance,
		SETTINGS.minimum_coverage)


func _reverse_and_shuffle(strokes: Array[PackedVector2Array]) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	for index in range(strokes.size() - 1, -1, -1):
		var stroke := strokes[index].duplicate()
		stroke.reverse()
		result.append(stroke)
	return result


func _augmentation_connects(strokes: Array[PackedVector2Array], augmentation: PackedVector2Array) -> bool:
	for base in strokes:
		for base_index in range(1, base.size()):
			for extra_index in range(1, augmentation.size()):
				if Geometry2D.segment_intersects_segment(base[base_index - 1], base[base_index],
						augmentation[extra_index - 1], augmentation[extra_index]) != null:
					return true
			for point in augmentation:
				if Geometry2D.get_closest_point_to_segment(point, base[base_index - 1], base[base_index]).distance_to(point) < 0.0001:
					return true
	return false


func _length(stroke: PackedVector2Array) -> float:
	var length := 0.0
	for index in range(1, stroke.size()):
		length += stroke[index - 1].distance_to(stroke[index])
	return length


func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		printerr(message)
	return condition
