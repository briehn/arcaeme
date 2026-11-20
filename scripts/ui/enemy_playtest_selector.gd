extends OptionButton

const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const STRENGTHENING_GOBLIN = preload("res://resources/prototype/enemies/strengthening_goblin.tres")
const DEFENSIVE_TREANT = preload("res://resources/prototype/enemies/defensive_treant.tres")
const ENCOUNTERS: Array[EncounterData] = [
	preload("res://resources/prototype/enemies/slime.tres"),
	preload("res://resources/prototype/enemies/goblin.tres"),
	preload("res://resources/prototype/enemies/treant.tres"),
	STRENGTHENING_GOBLIN,
	DEFENSIVE_TREANT,
]

@export var include_default := false


func _ready() -> void:
	if include_default:
		add_item("Default Enemy")
	for encounter in ENCOUNTERS:
		add_item(encounter.enemy_name)
		set_item_metadata(item_count - 1, encounter)
	select(0)


func selected_encounter() -> EncounterData:
	return get_selected_metadata() as EncounterData


func tactical_encounter_selected() -> bool:
	return selected_encounter() in [STRENGTHENING_GOBLIN, DEFENSIVE_TREANT]
