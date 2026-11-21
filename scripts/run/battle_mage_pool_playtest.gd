extends RefCounted

const CardData = preload("res://scripts/combat/card_data.gd")
const RunData = preload("res://scripts/run/run_data.gd")

const OFFER_COUNT := 3
const EXISTING_EXPANSION_CARDS: Array[CardData] = [
	preload("res://resources/prototype/cards/expansion/astral_salvo.tres"),
	preload("res://resources/prototype/cards/expansion/rune_cut.tres"),
	preload("res://resources/prototype/cards/expansion/warded_strike.tres"),
	preload("res://resources/prototype/cards/expansion/prism_wall.tres"),
	preload("res://resources/prototype/cards/expansion/arcane_study.tres"),
	preload("res://resources/prototype/cards/expansion/spellforge.tres"),
]
const NEW_CARDS: Array[CardData] = [
	preload("res://resources/prototype/cards/pool_expansion/twin_sigil.tres"),
	preload("res://resources/prototype/cards/pool_expansion/keystone_cut.tres"),
	preload("res://resources/prototype/cards/pool_expansion/spellsteel_oath.tres"),
	preload("res://resources/prototype/cards/pool_expansion/aegis_temper.tres"),
	preload("res://resources/prototype/cards/pool_expansion/mirror_lunge.tres"),
	preload("res://resources/prototype/cards/pool_expansion/glimmer_ward.tres"),
	preload("res://resources/prototype/cards/pool_expansion/tacticians_page.tres"),
	preload("res://resources/prototype/cards/pool_expansion/rune_survey.tres"),
	preload("res://resources/prototype/cards/pool_expansion/kindled_focus.tres"),
	preload("res://resources/prototype/cards/pool_expansion/ember_script.tres"),
	preload("res://resources/prototype/cards/pool_expansion/searing_brand.tres"),
	preload("res://resources/prototype/cards/pool_expansion/shatterguard.tres"),
]


static func with_expanded_rewards(template: RunData) -> RunData:
	var fixture: RunData = template.duplicate()
	fixture.reward_candidates = template.reward_candidates.duplicate()
	fixture.reward_candidates.append_array(EXISTING_EXPANSION_CARDS)
	fixture.reward_candidates.append_array(NEW_CARDS)
	fixture.reward_offer_count = OFFER_COUNT
	return fixture
