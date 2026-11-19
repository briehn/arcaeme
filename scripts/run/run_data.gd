extends Resource

const CardData = preload("res://scripts/combat/card_data.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const BATTLE_MAGE := &"battle_mage"

@export_group("Provisional Battle Mage Run")
@export var run_seed: int
@export var player_max_hp: int
@export var starting_deck: Array[CardData] = []
@export var opening_encounters: Array[EncounterData] = []
@export var boss_encounter: EncounterData
@export var reward_candidates: Array[CardData] = []


func eligible_rewards(class_id: StringName) -> Array[CardData]:
	var offers: Array[CardData] = []
	var seen_ids: Dictionary[StringName, bool] = {}
	for card in reward_candidates:
		if card != null and card.owner_class_id == class_id and card.id != &"" and not seen_ids.has(card.id):
			offers.append(card)
			seen_ids[card.id] = true
	return offers
