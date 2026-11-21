extends Resource

const CardData = preload("res://scripts/combat/card_data.gd")

@export var minimum_extent := 0.22
@export var recognition_tolerance := 0.18
@export var clean_score := 0.80
@export var rough_power_percent := 85
@export var clean_power_percent := 100
@export var booster_bonus_percent := 20
@export var test_deck: Array[CardData] = []


func power_percent(score: float, boosted: bool) -> int:
	var base := clean_power_percent if score >= clean_score else rough_power_percent
	return base + (booster_bonus_percent if boosted else 0)
