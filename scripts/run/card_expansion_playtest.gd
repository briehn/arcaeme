extends RefCounted

const CardData = preload("res://scripts/combat/card_data.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const RunData = preload("res://scripts/run/run_data.gd")

const BASIC_STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const DECK: Array[CardData] = [
	BASIC_STRIKE,
	BASIC_STRIKE,
	preload("res://resources/prototype/cards/basic_block.tres"),
	preload("res://resources/prototype/cards/arcane_guard.tres"),
	preload("res://resources/prototype/cards/battle_preparation.tres"),
	preload("res://resources/prototype/cards/expansion/astral_salvo.tres"),
	preload("res://resources/prototype/cards/expansion/rune_cut.tres"),
	preload("res://resources/prototype/cards/expansion/warded_strike.tres"),
	preload("res://resources/prototype/cards/expansion/prism_wall.tres"),
	preload("res://resources/prototype/cards/expansion/arcane_study.tres"),
	preload("res://resources/prototype/cards/expansion/spellforge.tres"),
]


static func with_expansion_deck(encounter: EncounterData) -> EncounterData:
	var fixture: EncounterData = encounter.duplicate()
	fixture.test_deck = DECK.duplicate()
	return fixture


static func with_expansion_run(template: RunData) -> RunData:
	var fixture: RunData = template.duplicate()
	fixture.title = template.title + " / Card Expansion"
	fixture.starting_deck = DECK.duplicate()
	return fixture
