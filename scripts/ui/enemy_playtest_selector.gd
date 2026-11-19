extends OptionButton

const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const ENCOUNTERS: Array[EncounterData] = [
	preload("res://resources/prototype/enemies/slime.tres"),
	preload("res://resources/prototype/enemies/goblin.tres"),
	preload("res://resources/prototype/enemies/treant.tres"),
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
