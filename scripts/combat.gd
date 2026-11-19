extends Control

const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const ViewSnapshot = preload("res://scripts/combat/combat_view_snapshot.gd")
const PLAYER_ID := &"Battle Mage"

signal encounter_finished(combat: CombatState)
signal network_card_requested(copy_id: int)
signal network_end_turn_requested

@export var encounter: EncounterData
@export var player_ids: Array[StringName] = [PLAYER_ID]

@onready var turn_label: Label = %TurnLabel
@onready var player_label: Label = %PlayerLabel
@onready var enemy_label: Label = %EnemyLabel
@onready var cards_label: Label = %CardsLabel
@onready var player_selector: HBoxContainer = %PlayerSelector
@onready var hand_cards: HFlowContainer = %HandCards
@onready var combat_log: RichTextLabel = %CombatLog
@onready var end_turn_button: Button = %EndTurnButton

var _state: CombatState
var _selected_player_id: StringName
var _card_buttons: Dictionary[int, Button] = {}
var _shown_log_lines := 0
var _run_title: String
var _network_mode := false


func configure_run(combat: CombatState, run_encounter: EncounterData, title: String) -> void:
	_state = combat
	encounter = run_encounter
	_run_title = title


func configure_network() -> void:
	_network_mode = true


func display_network_snapshot(snapshot: Dictionary, input_allowed: bool) -> void:
	_render_snapshot(snapshot, input_allowed)


func clear_network_view() -> void:
	combat_log.clear()
	_shown_log_lines = 0
	_render_hand([], false)


func _ready() -> void:
	if _network_mode:
		%TitleLabel.text = "Network Battle Mage Co-op Test"
		%BackButton.hide()
		return
	if _state == null:
		_state = CombatState.new(encounter, encounter.shuffle_seed, player_ids)
	_selected_player_id = _state.players.keys()[0]
	if not _run_title.is_empty():
		%TitleLabel.text = _run_title
	elif _state.players.size() > 1:
		%TitleLabel.text = "Local Battle Mage Co-op Playtest"
	if _state.players.size() > 1:
		_setup_player_selector()
	_render()


func _render() -> void:
	_render_snapshot(ViewSnapshot.build(_state, encounter, _selected_player_id, true), true)


func _render_snapshot(snapshot: Dictionary, input_allowed: bool) -> void:
	var party := snapshot["players"] as Array
	var coop := party.size() > 1
	var phase: int = snapshot["phase"]
	var in_combat := phase == CombatState.Phase.PLAYER
	match phase:
		CombatState.Phase.VICTORY:
			turn_label.text = "Team Victory" if coop else "Victory"
		CombatState.Phase.DEFEAT:
			turn_label.text = "Party Defeat" if coop else "Defeat"
		_:
			turn_label.text = "Turn %d  /  %s" % [snapshot["round"], "Shared player phase" if coop else "Your turn"]
	var stats := PackedStringArray()
	for party_member in party:
		stats.append(_player_stats(party_member, coop, phase))
	player_label.text = "\n".join(stats)
	enemy_label.text = "%s   ·   HP %d/%d" % [
		snapshot["enemy_name"], snapshot["enemy_hp"], snapshot["enemy_max_hp"]]
	if in_combat:
		var intent := "Attack all living players for %d damage each" if coop else "Attack for %d damage"
		enemy_label.text += "   ·   Intent: " + (intent % snapshot["enemy_attack"])
	var hand: Array = snapshot["hand"]
	cards_label.text = "Hand %d   ·   Draw pile %d   ·   Discard pile %d" % [
		hand.size(), snapshot["draw_count"], snapshot["discard_count"]]
	if snapshot.has("seed"):
		cards_label.text += "   ·   Seed %d" % snapshot["seed"]
	var continue_run := not in_combat and not _run_title.is_empty()
	end_turn_button.text = "Continue Run" if continue_run else "End Turn"
	if coop:
		cards_label.text = "%s   ·   %s" % [snapshot["viewer"], cards_label.text]
		if not continue_run:
			end_turn_button.text = "End Turn · %s" % snapshot["viewer"]
	end_turn_button.disabled = not continue_run and (not input_allowed or not snapshot["can_end_turn"])
	_render_hand(hand, input_allowed)
	var log_lines: PackedStringArray = snapshot["log"]
	while _shown_log_lines < log_lines.size():
		combat_log.add_text(log_lines[_shown_log_lines] + "\n")
		_shown_log_lines += 1


func _player_stats(player: Dictionary, show_turn_status: bool, phase: int) -> String:
	var stats := "%s   ·   HP %d/%d   ·   Mana %d/%d   ·   Block %d" % [
		player.id, player.hp, player.max_hp, player.mana, CombatState.TURN_MANA, player.block]
	if player.next_attack_bonus > 0:
		stats += "   ·   Next Attack +%d damage" % player.next_attack_bonus
	if show_turn_status:
		var status := "Ready"
		if player.recovered:
			status = "Recovered after victory"
		elif player.hp == 0:
			status = "Defeated"
		elif phase == CombatState.Phase.VICTORY:
			status = "Survived"
		elif player.ended_turn:
			status = "Turn ended"
		stats += "   ·   " + status
	return stats


func _setup_player_selector() -> void:
	var group := ButtonGroup.new()
	for player_id in _state.players:
		var button := Button.new()
		button.text = String(player_id)
		button.toggle_mode = true
		button.button_group = group
		button.button_pressed = player_id == _selected_player_id
		button.pressed.connect(_on_player_selected.bind(player_id))
		player_selector.add_child(button)
	player_selector.show()


func _on_player_selected(player_id: StringName) -> void:
	if player_id != _selected_player_id:
		_selected_player_id = player_id
		_render()


func _render_hand(hand: Array, input_allowed: bool) -> void:
	var hand_copies: Array[int] = []
	for card in hand:
		hand_copies.append(card.copy)
	var refresh_focus := false
	for copy_id in _card_buttons.keys():
		if not hand_copies.has(copy_id):
			var button := _card_buttons[copy_id]
			refresh_focus = refresh_focus or button.has_focus()
			hand_cards.remove_child(button)
			button.queue_free()
			_card_buttons.erase(copy_id)
	for hand_index in hand.size():
		var card: Dictionary = hand[hand_index]
		var copy_id: int = card.copy
		var button: Button = _card_buttons.get(copy_id)
		if button == null:
			button = Button.new()
			button.custom_minimum_size = Vector2(195, 112)
			button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			button.text = "%s\n%d Mana\n\n%s" % [card.name, card.cost, card.description]
			button.tooltip_text = "%s %s" % [card.approval, "Attack" if card.attack else "card"]
			button.pressed.connect(_on_card_pressed.bind(copy_id))
			hand_cards.add_child(button)
			_card_buttons[copy_id] = button
		hand_cards.move_child(button, hand_index)
		button.disabled = not input_allowed or not card.playable
		if refresh_focus and not button.disabled:
			button.grab_focus()
			refresh_focus = false
	if refresh_focus:
		if not end_turn_button.disabled:
			end_turn_button.grab_focus()
		elif %BackButton.is_visible_in_tree():
			%BackButton.grab_focus()


func _on_card_pressed(copy_id: int) -> void:
	if _network_mode:
		network_card_requested.emit(copy_id)
		return
	var target := encounter.enemy_id if _state.card_data(copy_id).targets_enemy() else &""
	if _state.play_card(_selected_player_id, copy_id, target):
		_render()


func _on_end_turn_button_pressed() -> void:
	if _network_mode:
		network_end_turn_requested.emit()
		return
	if not _run_title.is_empty() and (_state.phase == CombatState.Phase.VICTORY or _state.phase == CombatState.Phase.DEFEAT):
		encounter_finished.emit(_state)
		return
	if _state.end_turn(_selected_player_id):
		_render()


func _on_back_button_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")
