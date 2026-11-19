extends Control

func _on_button_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/combat.tscn")


func _on_start_run_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/prototype_run.tscn")


func _on_start_local_coop_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/local_coop.tscn")


func _on_start_network_coop_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/network_coop.tscn")
