extends RefCounted

const EnemyData = preload("res://scripts/combat/enemy_data.gd")
const EnemyAction = preload("res://scripts/combat/enemy_action.gd")

var id: StringName:
	get: return _data.id
var display_name: String:
	get: return _data.display_name
var max_hp: int:
	get: return _data.max_hp
var poison_per_attack: int:
	get: return _data.poison_per_attack
var burning_per_attack: int:
	get: return _data.burning_per_attack
var hp: int
var block: int
var strength: int
var dexterity: int
var poison: int
var burning: int
## Counts completed actions. A dead enemy never advances its cycle again.
var action_index: int

var _data: EnemyData


func _init(data: EnemyData) -> void:
	_data = data
	hp = max_hp
	# Negative modifiers are not supported until their rules are approved.
	strength = maxi(0, data.starting_strength)
	dexterity = maxi(0, data.starting_dexterity)


func is_alive() -> bool:
	return hp > 0


func intent() -> Dictionary:
	if not is_alive():
		return {}
	return intent_at(action_index)


func intent_at(index: int) -> Dictionary:
	var cycle := _data.action_cycle
	if not cycle.is_empty():
		var action := cycle[index % cycle.size()]
		if action != null:
			var bonus := strength if action.kind == EnemyAction.Kind.ATTACK else 0
			return {"kind": int(action.kind), "amount": maxi(0, action.amount) + bonus}
	var pattern := _data.attack_pattern
	var base_damage := _data.attack if pattern.is_empty() else pattern[index % pattern.size()]
	return {"kind": int(EnemyAction.Kind.ATTACK), "amount": maxi(0, base_damage) + strength}
