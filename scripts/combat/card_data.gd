extends Resource

const CardEffect = preload("res://scripts/combat/card_effect.gd")

@export var id: StringName
@export var display_name: String
@export var mana_cost: int
@export var approval_status: String = "Provisional"
@export var is_attack: bool
## Leave empty for unclassified cards. Use &"universal" for Universal Cards.
@export var owner_class_id: StringName
@export var effects: Array[CardEffect] = []


func description() -> String:
	var lines := PackedStringArray()
	for effect in effects:
		lines.append(effect.describe())
	return " ".join(lines)


func targets_enemy() -> bool:
	for effect in effects:
		if effect.targets_enemy():
			return true
	return false
