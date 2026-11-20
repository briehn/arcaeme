extends RefCounted

const EncounterData = preload("res://scripts/combat/encounter_data.gd")

const START := &"two_slimes"
const BOSS := &"citadel_warden"
const ENCOUNTERS := {
	START: preload("res://resources/prototype/enemies/two_slimes.tres"),
	&"goblin_treant": preload("res://resources/prototype/enemies/goblin_treant.tres"),
	&"three_enemies": preload("res://resources/prototype/enemies/three_enemies.tres"),
	&"slime": preload("res://resources/prototype/enemies/slime.tres"),
	&"goblin": preload("res://resources/prototype/enemies/goblin.tres"),
	&"treant": preload("res://resources/prototype/enemies/treant.tres"),
	BOSS: preload("res://resources/prototype/enemies/citadel_warden.tres"),
}

var _edges: Dictionary[StringName, Array] = {}
var _choice_rng := RandomNumberGenerator.new()


func _init(run_seed: int) -> void:
	# Route previews and party draws each have their own stream, separate from combat.
	var route_rng := RandomNumberGenerator.new()
	route_rng.seed = run_seed ^ 0x504f5254
	_choice_rng.seed = run_seed ^ 0x564f5445
	var first: Array[StringName] = [&"goblin_treant", &"three_enemies"]
	var second: Array[StringName] = [&"slime", &"goblin", &"treant"]
	_shuffle(first, route_rng)
	_shuffle(second, route_rng)
	_edges[START] = first
	_edges[&"goblin_treant"] = second.slice(0, 2)
	_edges[&"three_enemies"] = second.slice(1)
	for id in second:
		_edges[id] = [BOSS]


func options(source_id: StringName) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for target: StringName in _edges.get(source_id, []):
		var branches: Array[Dictionary] = []
		for next: StringName in _edges.get(target, []):
			branches.append(_preview(next))
		var option := _preview(target)
		option.merge({"id": String(_portal_id(source_id, target)), "destination_id": String(target), "branches": branches})
		result.append(option)
	return result


func destination(source_id: StringName, portal_id: StringName) -> EncounterData:
	for target: StringName in _edges.get(source_id, []):
		if portal_id == _portal_id(source_id, target):
			return ENCOUNTERS[target]
	return null


func resolve(choices: Array[StringName]) -> StringName:
	if choices.is_empty():
		return &""
	# Each submitted seat contributes one entry, including repeated IDs.
	return choices[_choice_rng.randi_range(0, choices.size() - 1)]


func _preview(id: StringName) -> Dictionary:
	var encounter: EncounterData = ENCOUNTERS[id]
	return {"name": encounter.enemy_name, "type": "Boss" if id == BOSS else "Combat"}


func _portal_id(source_id: StringName, target: StringName) -> StringName:
	return StringName("%s__%s" % [source_id, target])


func _shuffle(ids: Array[StringName], rng: RandomNumberGenerator) -> void:
	for index in range(ids.size() - 1, 0, -1):
		var other := rng.randi_range(0, index)
		var previous := ids[index]
		ids[index] = ids[other]
		ids[other] = previous
