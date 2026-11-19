extends SceneTree

const MENU := "res://scenes/main.tscn"
const COOP := "res://scenes/local_coop.tscn"
const ONE := "Battle Mage 1"
const TWO := "Battle Mage 2"

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	create_timer(10).timeout.connect(_on_timeout)
	var main_scene: String = ProjectSettings.get_setting("application/run/main_scene")
	if change_scene_to_file(main_scene) != OK:
		push_error("Could not open the main menu.")
		quit(1)
		return
	await scene_changed
	await _open_coop()
	_check(current_scene.scene_file_path == COOP and _text("%TurnLabel") == "Turn 1  /  Shared player phase",
		"Start Local Co-op Test opens the shared phase")
	_check("HP 25/25" in _stats(0) and "HP 25/25" in _stats(1) and "Ready" in _stats(0) and "Ready" in _stats(1),
		"both players' identities, health and turn status are visible")
	_check("Attack all living players for 13 damage each" in _text("%EnemyLabel"), "enemy telegraphs damage per player")
	_check(_text("%CardsLabel").begins_with(ONE) and _find_button("%HandCards", "Shieldstrike") != null,
		"the first player has their own starting hand")
	_select(TWO)
	_check(_text("%CardsLabel").begins_with(TWO) and _find_button("%HandCards", "Shieldstrike") == null and
		_find_button("%HandCards", "Basic Block") != null, "switching shows the second player's different hand and piles")
	_play("Basic Strike")
	_check("Mana 3/3" in _stats(0) and "Mana 2/3" in _stats(1) and "HP 36/42" in _text("%EnemyLabel"),
		"player two plays first and only their Mana changes")
	_end_turn()
	var end_button: Button = current_scene.get_node("%EndTurnButton")
	_check(_text("%TurnLabel").begins_with("Turn 1") and "Turn ended" in _stats(1) and "HP 25/25" in _stats(1) and
		end_button.disabled and "Hand 0" in _text("%CardsLabel"), "ending first waits for the other player")
	_select(ONE)
	_play("Arcane Guard")
	_play("Battle Preparation")
	_check("Block 14" in _stats(0) and "Next Attack +3 damage" in _stats(0) and "Block 0" in _stats(1),
		"the HUD shows the selected owner's Block and preparation separately")
	_play("Shieldstrike")
	_end_turn()
	_check(_text("%TurnLabel").begins_with("Turn 2") and "HP 25/25" in _stats(0) and "HP 12/25" in _stats(1) and
		"Mana 3/3" in _stats(0) and "Mana 3/3" in _stats(1), "the attack hits both and Mana refreshes for both")
	_check("Battle Mage 1 blocked 13 and lost 0 HP." in _log() and "Battle Mage 2 blocked 0 and lost 13 HP." in _log(),
		"the combat log names each player's own mitigation and damage")
	_select(TWO)
	_end_turn()
	_select(ONE)
	_play("Basic Block")
	_play("Battle Preparation")
	_play("Arcane Reversal")
	_end_turn()
	_check(_text("%TurnLabel").begins_with("Turn 3") and "HP 18/25" in _stats(0) and
		"HP 0/25" in _stats(1) and "Defeated" in _stats(1), "one player goes down and the survivor can continue")
	_select(TWO)
	_check(end_button.disabled and "Hand 0" in _text("%CardsLabel"), "the defeated player has no available actions")
	_select(ONE)
	_play("Shieldstrike")
	_check(_text("%TurnLabel") == "Team Victory" and "HP 18/25" in _stats(0) and "Survived" in _stats(0) and
		"HP 7/25" in _stats(1) and "Recovered after victory" in _stats(1), "team victory displays both final HP totals")
	_check("Battle Mage 2 recovered to 7/25 HP after victory." in _log() and end_button.disabled,
		"recovery is logged and actions remain closed")
	await _back_to_menu()
	await _open_coop()
	for _turn in 2:
		_select(ONE)
		_end_turn()
		_select(TWO)
		_end_turn()
	_check(_text("%TurnLabel") == "Party Defeat" and "HP 0/25" in _stats(0) and "HP 0/25" in _stats(1) and
		"recovered" not in _log(), "both players can fall with no recovery")
	await _back_to_menu()
	print("Co-op combat UI: %d checks, %d failures." % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _open_coop() -> void:
	var button: Button = current_scene.get_node("%StartLocalCoopButton")
	button.pressed.emit()
	await scene_changed


func _back_to_menu() -> void:
	var button: Button = current_scene.get_node("%BackButton")
	button.pressed.emit()
	await scene_changed
	_check(current_scene.scene_file_path == MENU, "Back to Menu closes the co-op encounter")


func _select(player: String) -> void:
	_press(_find_button("%PlayerSelector", player), player)
	_check(_text("%CardsLabel").begins_with(player), "display the selected player's cards")


func _play(card_name: String) -> void:
	_press(_find_button("%HandCards", card_name + "\n"), card_name)


func _end_turn() -> void:
	_press(current_scene.get_node("%EndTurnButton"), "the selected player's End Turn")


func _press(button: Button, context: String) -> void:
	_check(button != null and not button.disabled, "can click %s" % context)
	if button != null and not button.disabled:
		button.pressed.emit()


func _find_button(path: String, prefix: String) -> Button:
	for button: Button in current_scene.get_node(path).get_children():
		if button.text.begins_with(prefix):
			return button
	return null


func _stats(index: int) -> String:
	return _text("%PlayerLabel").get_slice("\n", index)


func _text(path: String) -> String:
	var label: Label = current_scene.get_node(path)
	return label.text


func _log() -> String:
	var log: RichTextLabel = current_scene.get_node("%CombatLog")
	return log.get_parsed_text()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)


func _on_timeout() -> void:
	push_error("The co-op combat UI test timed out.")
	quit(1)
