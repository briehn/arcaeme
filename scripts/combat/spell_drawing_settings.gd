extends Resource

const CardData = preload("res://scripts/combat/card_data.gd")

@export var minimum_extent := 0.22
@export var recognition_tolerance := 0.24
@export var minimum_coverage := 0.60
@export var acceptable_score := 0.40
@export var excellent_score := 0.82
@export var faint_power_percent := 75
@export var acceptable_power_percent := 100
@export var excellent_power_percent := 110
@export var booster_bonus_percent := 20
@export var test_deck: Array[CardData] = []


func quality(score: float, complete: bool) -> String:
	if not complete or score < acceptable_score:
		return "Faint"
	return "Excellent" if score >= excellent_score else "Acceptable"


func power_percent(cast_quality: String, boosted: bool) -> int:
	var base := faint_power_percent
	match cast_quality:
		"Acceptable": base = acceptable_power_percent
		"Excellent": base = excellent_power_percent
	return base + (booster_bonus_percent if boosted else 0)
