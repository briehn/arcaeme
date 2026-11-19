extends SceneTree

const MENU_PATH := "res://scenes/main.tscn"
const COMBAT_PATH := "res://scenes/combat.tscn"
const START_BUTTON := "CenterContainer/VBoxContainer/Button"

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	create_timer(5).timeout.connect(_on_timeout)
	var main_scene: String = ProjectSettings.get_setting("application/run/main_scene")
	if change_scene_to_file(main_scene) != OK:
		push_error("Could not launch the configured main scene.")
		quit(1)
		return
	await scene_changed
	_check(current_scene.scene_file_path == MENU_PATH, "the configured main scene is the existing menu")
	await _open_combat()
	_check(current_scene.scene_file_path == COMBAT_PATH, "Start Combat opens the combat scene")
	var player: Label = current_scene.get_node("%PlayerLabel")
	var enemy: Label = current_scene.get_node("%EnemyLabel")
	var turn: Label = current_scene.get_node("%TurnLabel")
	var hand: HFlowContainer = current_scene.get_node("%HandCards")
	var end_turn: Button = current_scene.get_node("%EndTurnButton")
	var log: RichTextLabel = current_scene.get_node("%CombatLog")
	_check("HP 36/36" in player.text and "Mana 3/3" in player.text and "Block 0" in player.text,
		"initial player stats are visible")
	_check("HP 34/34" in enemy.text and "Attack for 9 damage" in enemy.text, "enemy HP and intent are visible")
	_check(hand.get_child_count() == 5, "five visible buttons represent the opening hand")
	var preparation := _find_card(hand, "Battle Preparation")
	var reversal := _find_card(hand, "Arcane Reversal")
	var guard := _find_card(hand, "Arcane Guard")
	var shieldstrike := _find_card(hand, "Shieldstrike")
	if preparation == null or reversal == null or guard == null or shieldstrike == null:
		push_error("The default opening hand must contain all four candidates for the F5 walkthrough.")
		quit(1)
		return
	_check("1 Mana" in reversal.text and "If you have at least 6 Block" in reversal.text and
		"Your next Attack this turn deals 3 additional damage." in preparation.text,
		"the new cards show their cost and exact conditions")
	preparation.pressed.emit()
	_check("Block 7" in player.text and "Next Attack +3 damage" in player.text and "Mana 2/3" in player.text,
		"the HUD shows preparation, Block and Mana after playing Battle Preparation")
	reversal.pressed.emit()
	_check("Block 1" in player.text and "Next Attack" not in player.text and "HP 17/34" in enemy.text,
		"the HUD updates when a prepared Arcane Reversal spends Block")
	_check("spent 6 Block for +6 damage" in log.get_parsed_text() and
		"preparation for +3 Attack damage" in log.get_parsed_text(), "the log shows both damage bonuses")
	guard.pressed.emit()
	_check("Block 8" in player.text and hand.get_child_count() == 3 and "drew 1 card" in log.get_parsed_text(),
		"Arcane Guard displays the Block gain and replaces itself with a drawn card")
	var rounds := 0
	while turn.text != "Victory" and turn.text != "Defeat" and rounds < 10:
		for _play in 3:
			var card := _find_playable_card(hand)
			if card == null:
				break
			card.pressed.emit()
		if rounds == 0:
			_check("Mana 0/3" in player.text and "played" in log.get_parsed_text(),
				"clicking cards updates Mana and the visible log")
			for button: Button in hand.get_children():
				_check(button.disabled, "the UI disables unaffordable cards")
		if not end_turn.disabled:
			end_turn.pressed.emit()
		rounds += 1
	_check(turn.text == "Victory" and "HP 0/34" in enemy.text, "playing cards reaches visible victory")
	_check(end_turn.disabled and "Intent" not in enemy.text, "victory disables turns and clears enemy intent")
	await _back_to_menu()
	_check(current_scene.scene_file_path == MENU_PATH, "Back to Menu works after victory")
	await _open_combat()
	player = current_scene.get_node("%PlayerLabel")
	enemy = current_scene.get_node("%EnemyLabel")
	turn = current_scene.get_node("%TurnLabel")
	hand = current_scene.get_node("%HandCards")
	log = current_scene.get_node("%CombatLog")
	_check("HP 36/36" in player.text and "Turn 1" in turn.text, "starting again resets combat")
	_find_card(hand, "Arcane Reversal").pressed.emit()
	_check("Block 0" in player.text and "HP 26/34" in enemy.text and "spent none" in log.get_parsed_text(),
		"an Arcane Reversal below threshold displays baseline damage and the failed condition")
	_find_card(hand, "Arcane Guard").pressed.emit()
	_find_card(hand, "Shieldstrike").pressed.emit()
	_check("Block 7" in player.text and "HP 16/34" in enemy.text and
		"Shieldstrike added 2 damage from 7 Block." in log.get_parsed_text(),
		"Shieldstrike shows scaling while preserving Guard's Block")
	await _back_to_menu()
	await _open_combat()
	player = current_scene.get_node("%PlayerLabel")
	turn = current_scene.get_node("%TurnLabel")
	end_turn = current_scene.get_node("%EndTurnButton")
	for _turn in 4:
		end_turn.pressed.emit()
	_check(turn.text == "Defeat" and "HP 0/36" in player.text and end_turn.disabled,
		"ending four turns without playing cards reaches visible defeat")
	await _back_to_menu()
	_check(current_scene.scene_file_path == MENU_PATH, "Back to Menu works after defeat")
	print("Combat UI: %d checks, %d failures." % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _open_combat() -> void:
	var button: Button = current_scene.get_node(START_BUTTON)
	button.pressed.emit()
	await scene_changed
	await process_frame


func _back_to_menu() -> void:
	var button: Button = current_scene.get_node("%BackButton")
	button.pressed.emit()
	await scene_changed


func _find_card(hand: HFlowContainer, card_name: String) -> Button:
	for button: Button in hand.get_children():
		if button.text.begins_with(card_name + "\n"):
			return button
	return null


func _find_playable_card(hand: HFlowContainer) -> Button:
	var fallback: Button = null
	for button: Button in hand.get_children():
		if button.disabled:
			continue
		if button.tooltip_text.ends_with(" Attack"):
			return button
		if fallback == null:
			fallback = button
	return fallback


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _on_timeout() -> void:
	push_error("The combat UI test timed out waiting for a scene transition.")
	quit(1)
