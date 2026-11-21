extends Resource

const CardData = preload("res://scripts/combat/card_data.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const BATTLE_MAGE := &"battle_mage"

@export_group("Provisional Battle Mage Run")
@export var title: String
@export var run_seed: int
@export var player_max_hp: int
@export var starting_deck: Array[CardData] = []
@export var opening_encounters: Array[EncounterData] = []
## Fixed encounters after the chosen opening and before the boss.
@export var intermediate_encounters: Array[EncounterData] = []
@export var boss_encounter: EncounterData
@export var reward_candidates: Array[CardData] = []
## Zero preserves the fixture's full list. A positive value samples a seeded subset.
@export var reward_offer_count := 0
@export var major_arcana_enabled := false
@export var portal_enabled := false


func encounter_count() -> int:
	if portal_enabled:
		return 4
	return intermediate_encounters.size() + 2


func encounter_after(encounter_id: int) -> EncounterData:
	if portal_enabled or encounter_id < 1 or encounter_id >= encounter_count():
		return null
	if encounter_id <= intermediate_encounters.size():
		return intermediate_encounters[encounter_id - 1]
	return boss_encounter


func eligible_rewards(class_id: StringName) -> Array[CardData]:
	var offers: Array[CardData] = []
	var seen_ids: Dictionary[StringName, bool] = {}
	for card in reward_candidates:
		if card != null and card.owner_class_id == class_id and card.id != &"" and not seen_ids.has(card.id):
			offers.append(card)
			seen_ids[card.id] = true
	return offers


func reward_offers(class_id: StringName, encounter_id: int, seat: int,
		offer_seed: Variant = null) -> Array[CardData]:
	var offers := eligible_rewards(class_id)
	if reward_offer_count <= 0 or reward_offer_count >= offers.size():
		return offers
	# Keep drafting independent of combat, portals, and the order seats submit.
	var source_seed := run_seed if offer_seed == null else int(offer_seed)
	var stream := "%d:%d:%d:%s:combat_rewards" % [source_seed, encounter_id, seat, class_id]
	var rng := RandomNumberGenerator.new()
	rng.seed = stream.sha256_buffer().decode_s64(0)
	for index in reward_offer_count:
		var chosen := rng.randi_range(index, offers.size() - 1)
		var previous := offers[index]
		offers[index] = offers[chosen]
		offers[chosen] = previous
	offers.resize(reward_offer_count)
	return offers
