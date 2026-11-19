extends Control

const CardData = preload("res://scripts/combat/card_data.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const CombatView = preload("res://scripts/combat.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const RunState = preload("res://scripts/run/run_state.gd")
const WrappedTextButton = preload("res://scripts/ui/wrapped_text_button.gd")
const COMBAT_SCENE = preload("res://scenes/combat.tscn")

@export var run_data: RunData

@onready var run_panel: MarginContainer = %RunPanel
@onready var heading: Label = %Heading
@onready var run_status: Label = %RunStatus
@onready var message: Label = %Message
@onready var choices: VBoxContainer = %Choices
@onready var deck_title: Label = %DeckTitle
@onready var deck_list: RichTextLabel = %DeckList
@onready var back_button: Button = %RunBackButton

var _run: RunState
var _combat_view: CombatView


func _ready() -> void:
	_run = RunState.new(run_data)
	_render_panel()


func _render_panel() -> void:
	for choice in choices.get_children():
		choices.remove_child(choice)
		choice.queue_free()
	message.text = ""
	match _run.stage:
		RunState.Stage.ROUTE:
			heading.text = "Choose an opening encounter"
			message.text = "Provisional encounter stats"
			for encounter in run_data.opening_encounters:
				_add_choice("%s\n%d HP  ·  Attacks for %d" % [encounter.enemy_name, encounter.enemy_max_hp,
					encounter.enemy_attack], _choose_opening.bind(encounter.enemy_id))
		RunState.Stage.REWARD:
			heading.text = "Choose a card reward"
			message.text = "Choose one provisional Battle Mage card for this run, or skip."
			for card in _run.reward_options():
				_add_choice("%s  ·  %d Mana\n%s" % [card.display_name, card.mana_cost, card.description()],
					_take_reward.bind(card.id))
			_add_choice("Skip Reward", _skip_reward)
		RunState.Stage.BOSS_READY:
			heading.text = "Ready for the boss"
			var reward := _run.selected_reward
			message.text = "Added %s to your run deck." % reward.display_name if reward != null else "Reward skipped."
			var boss := run_data.boss_encounter
			_add_choice("Fight %s\n%d HP  ·  Attacks for %d" % [boss.enemy_name, boss.enemy_max_hp,
				boss.enemy_attack], _start_boss)
		RunState.Stage.VICTORY:
			heading.text = "Run Victory"
			message.text = "You defeated %s and completed the prototype run." % _run.active_encounter.enemy_name
		RunState.Stage.DEFEAT:
			heading.text = "Run Defeat"
			message.text = "%s ended your run." % _run.active_encounter.enemy_name
	run_status.text = "Battle Mage  ·  HP %d/%d  ·  Run seed %d" % [_run.current_hp, _run.max_hp, _run.run_seed]
	_render_deck(_run.deck_cards())
	run_panel.show()
	var focus_target: Button = choices.get_child(0) if choices.get_child_count() > 0 else back_button
	focus_target.grab_focus()


func _render_deck(deck: Array[CardData]) -> void:
	deck_title.text = "Run deck  ·  %d cards" % deck.size()
	var copies: Dictionary[CardData, int] = {}
	for card in deck:
		copies[card] = copies.get(card, 0) + 1
	var lines := PackedStringArray()
	for card: CardData in copies:
		lines.append("%d × %s" % [copies[card], card.display_name])
	deck_list.text = "\n".join(lines)


func _add_choice(label: String, action: Callable) -> void:
	var button := WrappedTextButton.new()
	button.text = label
	button.custom_minimum_size.y = 56
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.pressed.connect(action)
	choices.add_child(button)


func _choose_opening(encounter_id: StringName) -> void:
	if _run.choose_opening(encounter_id):
		_show_combat("Prototype Run  /  Opening Encounter")


func _take_reward(card_id: StringName) -> void:
	if _run.take_reward(card_id):
		_render_panel()


func _skip_reward() -> void:
	if _run.skip_reward():
		_render_panel()


func _start_boss() -> void:
	if _run.start_boss():
		_show_combat("Prototype Run  /  Boss")


func _show_combat(title: String) -> void:
	run_panel.hide()
	_combat_view = COMBAT_SCENE.instantiate()
	_combat_view.configure_run(_run.active_combat, _run.active_encounter, title)
	_combat_view.encounter_finished.connect(_finish_encounter)
	add_child(_combat_view)


func _finish_encounter(combat: CombatState) -> void:
	if _run.finish_combat(combat):
		remove_child(_combat_view)
		_combat_view.queue_free()
		_combat_view = null
		_render_panel()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")
