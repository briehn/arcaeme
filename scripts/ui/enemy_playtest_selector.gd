extends OptionButton

const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const STRENGTHENING_GOBLIN = preload("res://resources/prototype/enemies/strengthening_goblin.tres")
const DEFENSIVE_TREANT = preload("res://resources/prototype/enemies/defensive_treant.tres")
const TWO_SLIMES = preload("res://resources/prototype/enemies/two_slimes.tres")
const GOBLIN_TREANT = preload("res://resources/prototype/enemies/goblin_treant.tres")
const THREE_ENEMIES = preload("res://resources/prototype/enemies/three_enemies.tres")
const ENCOUNTERS: Array[EncounterData] = [
	preload("res://resources/prototype/enemies/slime.tres"),
	preload("res://resources/prototype/enemies/goblin.tres"),
	preload("res://resources/prototype/enemies/treant.tres"),
	STRENGTHENING_GOBLIN,
	DEFENSIVE_TREANT,
	TWO_SLIMES,
	GOBLIN_TREANT,
	THREE_ENEMIES,
]

@export var include_default := false


func _ready() -> void:
	if include_default:
		add_item("Default Enemy")
	for encounter in ENCOUNTERS:
		var label := encounter.enemy_name
		if encounter == STRENGTHENING_GOBLIN:
			label += " (Strength fixture)"
		elif encounter == DEFENSIVE_TREANT:
			label += " (Block fixture)"
		elif not encounter.enemies.is_empty():
			label += " (Prototype)"
		add_item(label)
		set_item_metadata(item_count - 1, encounter)
	select(0)


func selected_encounter() -> EncounterData:
	return get_selected_metadata() as EncounterData


func tactical_encounter_selected() -> bool:
	var encounter := selected_encounter()
	return encounter != null and (encounter in [STRENGTHENING_GOBLIN, DEFENSIVE_TREANT]
		or not encounter.enemies.is_empty())
