extends Resource

const CardData = preload("res://scripts/combat/card_data.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")

@export_group("Provisional Battle Mage Run")
@export var run_seed: int
@export var player_max_hp: int
@export var starting_deck: Array[CardData] = []
@export var opening_encounters: Array[EncounterData] = []
@export var boss_encounter: EncounterData
@export var reward_candidates: Array[CardData] = []
