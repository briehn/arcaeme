extends Control

const CombatView = preload("res://scripts/combat.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const COMBAT_SCENE = preload("res://scenes/combat.tscn")
const EnemyPlaytestSelector = preload("res://scripts/ui/enemy_playtest_selector.gd")
const CardExpansionPlaytest = preload("res://scripts/run/card_expansion_playtest.gd")
const BattleMagePoolPlaytest = preload("res://scripts/run/battle_mage_pool_playtest.gd")
const PrototypeRunView = preload("res://scripts/prototype_run.gd")
const PROTOTYPE_RUN_SCENE = preload("res://scenes/prototype_run.tscn")
const ENEMY_VARIETY_RUN_SCENE = preload("res://scenes/enemy_variety_run.tscn")
const MULTI_ENEMY_RUN = preload("res://resources/prototype/multi_enemy_run.tres")
const LOCAL_COOP_SCENE = preload("res://scenes/local_coop.tscn")
const SPELL_DRAWING = preload("res://resources/prototype/spell_drawing_settings.tres")
const SPELL_INK_BOOSTER = preload("res://resources/prototype/cards/spell_ink_booster.tres")

@onready var enemy_playtest: EnemyPlaytestSelector = %EnemyPlaytest
@onready var card_expansion: CheckBox = %CardExpansion
@onready var major_arcana: CheckBox = %MajorArcana
@onready var portal_prototype: CheckBox = %PortalPrototype
@onready var battle_mage_pool: CheckBox = %BattleMagePool
@onready var spell_drawing: CheckBox = %SpellDrawing
@onready var spell_drawing_bypass: CheckBox = %SpellDrawingBypass

var _enemy_local_coop_button: Button


func _ready() -> void:
	enemy_playtest.item_selected.connect(_on_enemy_playtest_selected)
	resized.connect(_fit_logo_area)
	_fit_logo_area()
	var unchecked := _checkbox_marker(false)
	var checked := _checkbox_marker(true)
	for toggle: CheckBox in [major_arcana, portal_prototype, battle_mage_pool, card_expansion,
			spell_drawing, spell_drawing_bypass]:
		toggle.add_theme_icon_override(&"unchecked", unchecked)
		toggle.add_theme_icon_override(&"checked", checked)
	spell_drawing.toggled.connect(_set_drawing_bypass_available)


func _set_drawing_bypass_available(enabled: bool) -> void:
	spell_drawing_bypass.disabled = not enabled
	if not enabled:
		spell_drawing_bypass.set_pressed_no_signal(false)


func _fit_logo_area() -> void:
	# Leave the full primary stack visible at the smallest supported height.
	%LogoArea.custom_minimum_size.y = clampf(size.y * 0.27, 134.0, 172.0)


func _checkbox_marker(checked: bool) -> Texture2D:
	var image := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	image.fill_rect(Rect2i(1, 1, 14, 14), Color("#caafd4"))
	image.fill_rect(Rect2i(3, 3, 10, 10), Color("#20152e"))
	if checked:
		image.fill_rect(Rect2i(4, 4, 8, 8), Color("#f6d087"))
	return ImageTexture.create_from_image(image)


func _show_prototype_tools(show_tools: bool) -> void:
	%PrimaryNavigation.visible = not show_tools
	%PrototypeNavigation.visible = show_tools
	%BackFromTools.visible = show_tools
	%MenuScroll.scroll_vertical = 0
	var focus_target: Button = %BackFromTools if show_tools else %OpenPrototypeTools
	focus_target.grab_focus()


func _unhandled_key_input(event: InputEvent) -> void:
	if %PrototypeNavigation.visible and event.is_action_pressed(&"ui_cancel"):
		_show_prototype_tools(false)
		get_viewport().set_input_as_handled()


func _on_button_pressed() -> void:
	_launch_combat(COMBAT_SCENE.instantiate())


func _on_start_run_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/prototype_run.tscn")


func _on_start_enemy_variety_run_pressed() -> void:
	var run: PrototypeRunView = ENEMY_VARIETY_RUN_SCENE.instantiate()
	if card_expansion.button_pressed:
		run.run_data = CardExpansionPlaytest.with_expansion_run(run.run_data)
	get_tree().change_scene_to_node(run)


func _start_multi_enemy_run(local_coop: bool) -> void:
	var run: PrototypeRunView = PROTOTYPE_RUN_SCENE.instantiate()
	run.run_data = MULTI_ENEMY_RUN
	if major_arcana.button_pressed or portal_prototype.button_pressed:
		run.run_data = MULTI_ENEMY_RUN.duplicate()
		run.run_data.major_arcana_enabled = major_arcana.button_pressed
		run.run_data.portal_enabled = portal_prototype.button_pressed
	if battle_mage_pool.button_pressed:
		run.run_data = BattleMagePoolPlaytest.with_expanded_rewards(run.run_data)
	if spell_drawing.button_pressed:
		var pilot: RunData = run.run_data.duplicate()
		pilot.starting_deck = run.run_data.starting_deck.duplicate()
		pilot.starting_deck.append(SPELL_INK_BOOSTER)
		run.run_data = pilot
		run.spell_drawing = SPELL_DRAWING
		run.bypass_drawing = spell_drawing_bypass.button_pressed
	run.local_coop = local_coop
	get_tree().change_scene_to_node(run)


func _on_start_local_coop_pressed() -> void:
	_start_local_coop()


func _start_local_coop(encounter: EncounterData = null) -> void:
	var combat: CombatView = LOCAL_COOP_SCENE.instantiate()
	if encounter != null:
		combat.encounter = encounter
	if card_expansion.button_pressed:
		combat.encounter = CardExpansionPlaytest.with_expansion_deck(combat.encounter)
	_launch_combat(combat)


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
	_launch_combat(combat)


func _launch_combat(combat: CombatView) -> void:
	if spell_drawing.button_pressed:
		var fixture: EncounterData = combat.encounter.duplicate()
		fixture.test_deck = SPELL_DRAWING.test_deck.duplicate()
		combat.encounter = fixture
		combat.spell_drawing = SPELL_DRAWING
		combat.bypass_drawing = spell_drawing_bypass.button_pressed
	get_tree().change_scene_to_node(combat)


func _on_enemy_playtest_selected(_index: int) -> void:
	if enemy_playtest.tactical_encounter_selected():
		if _enemy_local_coop_button == null:
			_enemy_local_coop_button = Button.new()
			_enemy_local_coop_button.name = "StartEnemyLocalCoopButton"
			_enemy_local_coop_button.text = "Start Local Co-op"
			_enemy_local_coop_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
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
