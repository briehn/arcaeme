extends Control

const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const EnemyAction = preload("res://scripts/combat/enemy_action.gd")
const ViewSnapshot = preload("res://scripts/combat/combat_view_snapshot.gd")
const WrappedTextButton = preload("res://scripts/ui/wrapped_text_button.gd")
const PLAYER_ID := &"Battle Mage"
const TARGET_HIGHLIGHT := Color(0.98, 0.84, 0.56)

signal encounter_finished(combat: CombatState)
signal network_card_requested(copy_id: int, target_id: StringName)
signal network_end_turn_requested
signal network_undo_ready_requested

@export var encounter: EncounterData
@export var player_ids: Array[StringName] = [PLAYER_ID]

@onready var turn_label: Label = %TurnLabel
@onready var player_label: Label = %PlayerLabel
@onready var enemy_label: Label = %EnemyLabel
@onready var enemy_picker: VBoxContainer = %EnemyPicker
@onready var target_label: Label = %TargetLabel
@onready var enemy_targets: HFlowContainer = %EnemyTargets
@onready var cards_label: Label = %CardsLabel
@onready var arcana_label: Label = %ArcanaLabel
@onready var player_selector: HFlowContainer = %PlayerSelector
@onready var hand_cards: HFlowContainer = %HandCards
@onready var combat_log: RichTextLabel = %CombatLog
@onready var end_turn_button: Button = %EndTurnButton
@onready var cancel_target_button: Button = %CancelTargetButton

var _state: CombatState
var _selected_player_id: StringName
var _card_buttons: Dictionary[int, Button] = {}
var _shown_log_lines := 0
var _run_title: String
var _network_mode := false
var _displayed_encounter := -1
var _snapshot: Dictionary = {}
var _input_allowed := false
var _pending_card_copy := -1
var _living_enemy_ids: Array[StringName] = []
var _enemy_buttons: Dictionary[StringName, WrappedTextButton] = {}


func configure_run(combat: CombatState, run_encounter: EncounterData, title: String) -> void:
	_state = combat
	encounter = run_encounter
	_run_title = title


func configure_network() -> void:
	_network_mode = true


func display_network_snapshot(snapshot: Dictionary, input_allowed: bool) -> void:
	var encounter_id: int = snapshot.get("encounter_id", 0)
	if encounter_id != _displayed_encounter:
		clear_network_view()
		_displayed_encounter = encounter_id
	%TitleLabel.visible = not snapshot.has("run_stage")
	_render_snapshot(snapshot, input_allowed)


func clear_network_view() -> void:
	combat_log.clear()
	_shown_log_lines = 0
	_displayed_encounter = -1
	_snapshot = {}
	_input_allowed = false
	_pending_card_copy = -1
	cancel_target_button.hide()
	arcana_label.hide()
	arcana_label.text = ""
	arcana_label.tooltip_text = ""
	_living_enemy_ids.clear()
	_clear_enemy_buttons()
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
	if snapshot.get("viewer") != _snapshot.get("viewer") or snapshot.get("round") != _snapshot.get("round"):
		_pending_card_copy = -1
	_snapshot = snapshot
	_input_allowed = input_allowed
	var party := snapshot["players"] as Array
	var coop := party.size() > 1
	var phase: int = snapshot["phase"]
	var in_combat := phase == CombatState.Phase.PLAYER
	var hand: Array = snapshot["hand"]
	var pending_card_name := ""
	if in_combat and input_allowed and _pending_card_copy >= 0:
		for card: Dictionary in hand:
			if card.copy == _pending_card_copy and card.playable and card.get("targets_enemy", false):
				pending_card_name = card.name
				break
	if pending_card_name.is_empty():
		_pending_card_copy = -1
	cancel_target_button.visible = not pending_card_name.is_empty()
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
	_render_enemies(snapshot, in_combat, coop, pending_card_name)
	cards_label.text = "Hand %d   ·   Draw pile %d   ·   Discard pile %d" % [
		hand.size(), snapshot["draw_count"], snapshot["discard_count"]]
	if snapshot.has("seed"):
		cards_label.text += "   ·   Seed %d" % snapshot["seed"]
	var arcana: Dictionary = snapshot.get("arcana", {})
	arcana_label.visible = not arcana.is_empty()
	arcana_label.text = ""
	arcana_label.tooltip_text = ""
	if not arcana.is_empty():
		arcana_label.text = "Major Arcana: " + String(arcana.name)
		var progress := String(arcana.get("progress", ""))
		if not progress.is_empty():
			arcana_label.text += "  ·  " + progress
		arcana_label.tooltip_text = arcana.description
	var continue_run := not in_combat and not _run_title.is_empty()
	var can_undo: bool = snapshot.get("can_undo_ready", false)
	end_turn_button.text = "Undo Ready" if can_undo else "End Turn"
	if continue_run:
		end_turn_button.text = "Continue Run"
	if coop:
		cards_label.text = "%s   ·   %s" % [snapshot["viewer"], cards_label.text]
		if not continue_run:
			end_turn_button.text += " · %s" % snapshot["viewer"]
	end_turn_button.disabled = not continue_run and (not input_allowed or not (snapshot["can_end_turn"] or can_undo))
	_render_hand(hand, input_allowed)
	var log_lines: PackedStringArray = snapshot["log"]
	while _shown_log_lines < log_lines.size():
		combat_log.add_text(log_lines[_shown_log_lines] + "\n")
		_shown_log_lines += 1


func _render_enemies(snapshot: Dictionary, in_combat: bool, coop: bool, pending_card_name: String) -> void:
	var enemies: Array = snapshot.get("enemies", [])
	_living_enemy_ids.clear()
	for enemy: Dictionary in enemies:
		if enemy.alive:
			_living_enemy_ids.append(StringName(enemy.id))
	enemy_picker.visible = enemies.size() > 1
	enemy_label.visible = not enemy_picker.visible
	if enemy_label.visible:
		_render_single_enemy(snapshot, in_combat, coop)
		return
	_render_enemy_picker(enemies, in_combat, coop, pending_card_name)


func _render_single_enemy(snapshot: Dictionary, in_combat: bool, coop: bool) -> void:
	enemy_label.text = "%s   ·   HP %d/%d" % [
		snapshot["enemy_name"], snapshot["enemy_hp"], snapshot["enemy_max_hp"]]
	var enemy_block: int = snapshot.get("enemy_block", 0)
	if enemy_block > 0:
		enemy_label.text += "   ·   Block %d" % enemy_block
	enemy_label.text += _modifier_counters(snapshot.get("enemy_strength", 0), snapshot.get("enemy_dexterity", 0))
	enemy_label.text += _status_counters(snapshot.get("enemy_poison", 0), snapshot.get("enemy_burning", 0))
	if in_combat:
		var intent: Dictionary = snapshot.get("enemy_intent", {"amount": snapshot.get("enemy_attack", 0)})
		enemy_label.text += "   ·   Intent: " + _enemy_intent(intent, coop,
			snapshot.get("enemy_poison_per_attack", 0), snapshot.get("enemy_burning_per_attack", 0))


func _render_enemy_picker(enemies: Array, in_combat: bool, coop: bool, pending_card_name: String) -> void:
	var name_counts: Dictionary[String, int] = {}
	var name_indices: Dictionary[String, int] = {}
	for enemy: Dictionary in enemies:
		name_counts[enemy.name] = name_counts.get(enemy.name, 0) + 1
	var choosing_target := not pending_card_name.is_empty()
	target_label.visible = choosing_target
	target_label.text = "Choose a target for %s" % pending_card_name
	for index in enemies.size():
		var enemy: Dictionary = enemies[index]
		var enemy_id := StringName(enemy.id)
		var enemy_name: String = enemy.name
		if name_counts[enemy_name] > 1:
			name_indices[enemy_name] = name_indices.get(enemy_name, 0) + 1
			enemy_name = "%s (%d)" % [enemy_name, name_indices[enemy_name]]
		var button: WrappedTextButton = _enemy_buttons.get(enemy_id)
		if button == null:
			button = WrappedTextButton.new()
			button.custom_minimum_size = Vector2(250, 78)
			button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			button.pressed.connect(_on_enemy_selected.bind(enemy_id))
			enemy_targets.add_child(button)
			_enemy_buttons[enemy_id] = button
		var details := "%s\nHP %d/%d   ·   Block %d" % [enemy_name, enemy.hp, enemy.max_hp, enemy.block]
		details += _modifier_counters(enemy.strength, enemy.dexterity)
		details += _status_counters(enemy.poison, enemy.burning)
		if not enemy.alive:
			details += "\nDefeated"
		elif in_combat:
			details += "\nIntent: " + _enemy_intent(enemy.intent, coop, enemy.attack_poison, enemy.attack_burning)
		button.set_wrapped_text(details)
		button.disabled = not choosing_target or not enemy.alive
		_highlight_target_choice(button, not button.disabled)
		enemy_targets.move_child(button, index)


func _clear_enemy_buttons() -> void:
	for button in _enemy_buttons.values():
		enemy_targets.remove_child(button)
		button.queue_free()
	_enemy_buttons.clear()


func _on_enemy_selected(enemy_id: StringName) -> void:
	var button: Button = _enemy_buttons.get(enemy_id)
	if _pending_card_copy < 0 or button == null or button.disabled or not _living_enemy_ids.has(enemy_id):
		return
	_submit_card(_pending_card_copy, enemy_id)


func _enemy_intent(intent: Dictionary, coop: bool, poison_per_attack: int, burning_per_attack: int) -> String:
	var amount: int = intent.get("amount", 0)
	match intent.get("kind", EnemyAction.Kind.ATTACK):
		EnemyAction.Kind.BLOCK:
			return "Gain %d Block" % amount
		EnemyAction.Kind.GAIN_STRENGTH:
			return "Gain %d Strength" % amount
	var attack := "Attack all living players for %d damage each" if coop else "Attack for %d damage"
	var description := attack % amount
	if poison_per_attack > 0 or burning_per_attack > 0:
		description += "\nOn surviving targets" + _status_counters(poison_per_attack, burning_per_attack)
	return description


func _player_stats(player: Dictionary, show_turn_status: bool, phase: int) -> String:
	var stats := "%s   ·   HP %d/%d   ·   Mana %d/%d   ·   Block %d" % [
		player.id, player.hp, player.max_hp, player.mana, CombatState.TURN_MANA, player.block]
	if player.next_attack_bonus > 0:
		stats += "   ·   Next Attack +%d damage" % player.next_attack_bonus
	if show_turn_status:
		var status := "Not Ready"
		if player.recovered:
			status = "Recovered after victory"
		elif player.hp == 0:
			status = "Defeated"
		elif phase == CombatState.Phase.VICTORY:
			status = "Survived"
		elif player.ended_turn:
			status = "Ready"
		stats += "   ·   " + status
	stats += _modifier_counters(player.get("strength", 0), player.get("dexterity", 0))
	return stats + _status_counters(player.get("poison", 0), player.get("burning", 0))


func _modifier_counters(strength: int, dexterity: int) -> String:
	var counters := ""
	if strength > 0:
		counters += "   ·   Strength %d" % strength
	if dexterity > 0:
		counters += "   ·   Dexterity %d" % dexterity
	return counters


func _status_counters(poison: int, burning: int) -> String:
	var counters := ""
	if poison > 0:
		counters += "   ·   Poison %d" % poison
	if burning > 0:
		counters += "   ·   Burning %d" % burning
	return counters


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
			button = WrappedTextButton.new()
			button.custom_minimum_size = Vector2(195, 112)
			button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			button.text = "%s\n%d Mana\n\n%s" % [card.name, card.cost, card.description]
			button.tooltip_text = "%s %s" % [card.approval, "Attack" if card.attack else "card"]
			button.pressed.connect(_on_card_pressed.bind(copy_id))
			hand_cards.add_child(button)
			_card_buttons[copy_id] = button
		hand_cards.move_child(button, hand_index)
		var targets_enemy: bool = card.get("targets_enemy", false)
		button.set_meta("targets_enemy", targets_enemy)
		button.disabled = not input_allowed or not card.playable or (targets_enemy and _living_enemy_ids.is_empty())
		_highlight_target_choice(button, copy_id == _pending_card_copy)
		if refresh_focus and not button.disabled:
			button.grab_focus()
			refresh_focus = false
	if refresh_focus:
		if not end_turn_button.disabled:
			end_turn_button.grab_focus()
		elif %BackButton.is_visible_in_tree():
			%BackButton.grab_focus()


func _on_card_pressed(copy_id: int) -> void:
	var button: Button = _card_buttons.get(copy_id)
	if button == null or button.disabled:
		return
	if _pending_card_copy == copy_id:
		_cancel_targeting()
	elif not button.get_meta("targets_enemy"):
		_submit_card(copy_id, &"")
	elif _living_enemy_ids.size() == 1:
		_submit_card(copy_id, _living_enemy_ids[0])
	else:
		_pending_card_copy = copy_id
		_render_snapshot(_snapshot, _input_allowed)
		# At compact sizes, focusing a valid target brings the enemy row into view.
		_enemy_buttons[_living_enemy_ids[0]].grab_focus()


func _highlight_target_choice(button: Button, highlighted: bool) -> void:
	if button.has_theme_color_override("font_color") == highlighted:
		return
	if highlighted:
		button.add_theme_color_override("font_color", TARGET_HIGHLIGHT)
		button.add_theme_color_override("font_focus_color", TARGET_HIGHLIGHT)
	else:
		button.remove_theme_color_override("font_color")
		button.remove_theme_color_override("font_focus_color")


func _cancel_targeting() -> void:
	if _pending_card_copy < 0:
		return
	var button: Button = _card_buttons.get(_pending_card_copy)
	_pending_card_copy = -1
	_render_snapshot(_snapshot, _input_allowed)
	if button != null and not button.disabled:
		button.grab_focus()


func _submit_card(copy_id: int, target: StringName) -> void:
	_pending_card_copy = -1
	if _network_mode:
		_render_snapshot(_snapshot, _input_allowed)
		network_card_requested.emit(copy_id, target)
	else:
		_state.play_card(_selected_player_id, copy_id, target)
		_render()


func _input(event: InputEvent) -> void:
	# The same footer position can change from End Turn to Undo Ready, or start a new round.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed \
			and event.double_click and end_turn_button.is_visible_in_tree():
		var local_position: Vector2 = end_turn_button.get_global_transform_with_canvas().affine_inverse() * event.position
		if Rect2(Vector2.ZERO, end_turn_button.size).has_point(local_position):
			get_viewport().set_input_as_handled()


func _unhandled_key_input(event: InputEvent) -> void:
	if _pending_card_copy >= 0 and is_visible_in_tree() and event.is_action_pressed("ui_cancel"):
		_cancel_targeting()
		get_viewport().set_input_as_handled()


func _on_end_turn_button_pressed() -> void:
	if end_turn_button.disabled:
		return
	_pending_card_copy = -1
	var can_undo: bool = _snapshot.get("can_undo_ready", false)
	if _network_mode:
		_render_snapshot(_snapshot, _input_allowed)
		if can_undo:
			network_undo_ready_requested.emit()
		else:
			network_end_turn_requested.emit()
		return
	if not _run_title.is_empty() and (_state.phase == CombatState.Phase.VICTORY or _state.phase == CombatState.Phase.DEFEAT):
		encounter_finished.emit(_state)
		return
	var changed := _state.undo_ready(_selected_player_id) if can_undo else _state.end_turn(_selected_player_id)
	if changed:
		_render()


func _on_back_button_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")
