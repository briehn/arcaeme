extends Control

const CombatView = preload("res://scripts/combat.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const COMBAT_SCENE = preload("res://scenes/combat.tscn")
const EnemyPlaytestSelector = preload("res://scripts/ui/enemy_playtest_selector.gd")
const CardExpansionPlaytest = preload("res://scripts/run/card_expansion_playtest.gd")
const PrototypeRunView = preload("res://scripts/prototype_run.gd")
const ENEMY_VARIETY_RUN_SCENE = preload("res://scenes/enemy_variety_run.tscn")
const LOCAL_COOP_SCENE = preload("res://scenes/local_coop.tscn")

@onready var enemy_playtest: EnemyPlaytestSelector = %EnemyPlaytest
@onready var card_expansion: CheckBox = %CardExpansion

var _enemy_local_coop_button: Button


func _ready() -> void:
	enemy_playtest.item_selected.connect(_on_enemy_playtest_selected)


func _on_button_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/combat.tscn")


func _on_start_run_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/prototype_run.tscn")


func _on_start_enemy_variety_run_pressed() -> void:
	var run: PrototypeRunView = ENEMY_VARIETY_RUN_SCENE.instantiate()
	if card_expansion.button_pressed:
		run.run_data = CardExpansionPlaytest.with_expansion_run(run.run_data)
	get_tree().change_scene_to_node(run)


func _on_start_local_coop_pressed() -> void:
	_start_local_coop()


func _start_local_coop(encounter: EncounterData = null) -> void:
	var combat: CombatView = LOCAL_COOP_SCENE.instantiate()
	if encounter != null:
		combat.encounter = encounter
	if card_expansion.button_pressed:
		combat.encounter = CardExpansionPlaytest.with_expansion_deck(combat.encounter)
	get_tree().change_scene_to_node(combat)


func _on_start_network_coop_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/network_coop.tscn")


func _on_start_status_playtest_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/status_playtest.tscn")


func _on_start_modifier_playtest_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/modifier_playtest.tscn")


func _on_start_enemy_playtest_pressed() -> void:
	var combat: CombatView = COMBAT_SCENE.instantiate()
	combat.encounter = enemy_playtest.selected_encounter()
	if card_expansion.button_pressed:
		combat.encounter = CardExpansionPlaytest.with_expansion_deck(combat.encounter)
	get_tree().change_scene_to_node(combat)


func _on_enemy_playtest_selected(_index: int) -> void:
	if enemy_playtest.tactical_encounter_selected():
		if _enemy_local_coop_button == null:
			_enemy_local_coop_button = Button.new()
			_enemy_local_coop_button.name = "StartEnemyLocalCoopButton"
			_enemy_local_coop_button.text = "Start Local Co-op"
			_enemy_local_coop_button.pressed.connect(_on_start_enemy_local_coop_pressed)
			enemy_playtest.get_parent().add_child(_enemy_local_coop_button)
			_enemy_local_coop_button.owner = self
			_enemy_local_coop_button.unique_name_in_owner = true
	elif _enemy_local_coop_button != null:
		enemy_playtest.get_parent().remove_child(_enemy_local_coop_button)
		_enemy_local_coop_button.queue_free()
		_enemy_local_coop_button = null


func _on_start_enemy_local_coop_pressed() -> void:
	_start_local_coop(enemy_playtest.selected_encounter())
