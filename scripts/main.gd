extends Control

const CombatView = preload("res://scripts/combat.gd")
const COMBAT_SCENE = preload("res://scenes/combat.tscn")
const EnemyPlaytestSelector = preload("res://scripts/ui/enemy_playtest_selector.gd")

@onready var enemy_playtest: EnemyPlaytestSelector = %EnemyPlaytest


func _on_button_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/combat.tscn")


func _on_start_run_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/prototype_run.tscn")


func _on_start_local_coop_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/local_coop.tscn")


func _on_start_network_coop_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/network_coop.tscn")


func _on_start_status_playtest_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/status_playtest.tscn")


func _on_start_modifier_playtest_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/modifier_playtest.tscn")


func _on_start_enemy_playtest_pressed() -> void:
	var combat: CombatView = COMBAT_SCENE.instantiate()
	combat.encounter = enemy_playtest.selected_encounter()
	get_tree().change_scene_to_node(combat)
