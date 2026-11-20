extends SceneTree

const MENU_PATH := "res://scenes/main.tscn"
const RUN_PATH := "res://scenes/prototype_run.tscn"

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
	await _open_run()
	_check(current_scene.scene_file_path == RUN_PATH and _text("%Heading") == "Choose an opening encounter",
		"Start Prototype Run opens the route screen")
	_check(current_scene.get_node("%Choices").get_child_count() == 2 and "11 cards" in _text("%DeckTitle") and
		"HP 36/36" in _text("%RunStatus"), "two routes, starting HP and the deck are visible")
	_pick("Gate Sentinel")
	_check(_combat_text("%EnemyLabel").begins_with("Gate Sentinel") and "Attack for 7 damage" in _combat_text("%EnemyLabel"),
		"the selected first route opens the configured combat")
	_win_opening(2)
	_check(_text("%Heading") == "Choose a card reward" and "HP 34/36" in _text("%RunStatus"),
		"opening victory shows reward options and remaining HP")
	var offer := _find_button(current_scene.get_node("%Choices"), "Shieldstrike")
	_check(offer != null and "1 Mana" in offer.text and "Deal 8 damage." in offer.text,
		"reward choices show the card's current cost and text")
	_pick("Shieldstrike")
	_check(_text("%Heading") == "Ready for the boss" and "12 cards" in _text("%DeckTitle") and
		"1 × Shieldstrike" in _text("%DeckList") and "Added Shieldstrike" in _text("%Message"),
		"taking the reward visibly adds it to the run deck before the boss")
	_pick("Fight Citadel Warden")
	var stats := _combat_text("%PlayerLabel")
	_check("HP 34/36" in stats and "Mana 3/3" in stats and "Block 0" in stats and
		"Turn 1" in _combat_text("%TurnLabel") and "Discard pile 0" in _combat_text("%CardsLabel"),
		"boss HUD shows carried HP and fresh combat resources")
	_play("Shieldstrike")
	_check("HP 30/38" in _combat_text("%EnemyLabel"), "play the acquired Shieldstrike during the boss fight")
	_play("Basic Strike")
	_play("Basic Block")
	_combat_action("End Turn")
	for _strike in 3:
		_play("Basic Strike")
	_combat_action("End Turn")
	_play("Basic Strike")
	_combat_action("Continue Run")
	_check(_text("%Heading") == "Run Victory" and "HP 19/36" in _text("%RunStatus") and
		"1 × Shieldstrike" in _text("%DeckList"), "run victory summarizes the surviving HP and upgraded deck")
	await _return_to_menu()

	await _open_run()
	_pick("Rift Stalker")
	_check(_combat_text("%EnemyLabel").begins_with("Rift Stalker"), "the other route launches the Rift Stalker")
	_win_opening(1)
	_pick("Skip Reward")
	_check(_text("%Heading") == "Ready for the boss" and "Reward skipped" in _text("%Message") and
		"11 cards" in _text("%DeckTitle") and "HP 31/36" in _text("%RunStatus"),
		"skip preserves the starting deck and damage taken on the selected route")
	_pick("Fight Citadel Warden")
	_pass_until_defeat()
	_check(_text("%Heading") == "Run Defeat" and "Citadel Warden" in _text("%Message") and
		"HP 0/36" in _text("%RunStatus"), "boss defeat shows the run defeat screen")
	await _return_to_menu()

	await _open_run()
	_pick("Gate Sentinel")
	_pass_until_defeat()
	_check(_text("%Heading") == "Run Defeat" and "Gate Sentinel" in _text("%Message") and
		current_scene.get_node("%Choices").get_child_count() == 0, "opening defeat skips the reward and boss")
	await _return_to_menu()
	var standalone: Button = current_scene.get_node("%StartCombatButton")
	_check(standalone.text == "Start Combat", "the menu still offers the independent combat playtest")
	print("Run UI: %d checks, %d failures." % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _open_run() -> void:
	var button: Button = current_scene.get_node("%StartRunButton")
	button.pressed.emit()
	await scene_changed


func _return_to_menu() -> void:
	var button: Button = current_scene.get_node("%RunBackButton")
	button.pressed.emit()
	await scene_changed
	_check(current_scene.scene_file_path == MENU_PATH, "Back to Menu closes the completed run")


func _win_opening(second_turn_strikes: int) -> void:
	_play("Basic Strike")
	_play("Basic Strike")
	_play("Basic Block")
	_combat_action("End Turn")
	for _strike in second_turn_strikes:
		_play("Basic Strike")
	_combat_action("Continue Run")


func _pass_until_defeat() -> void:
	for _turn in 6:
		if _combat_text("%TurnLabel") == "Defeat":
			break
		_combat_action("End Turn")
	_combat_action("Continue Run")


func _pick(prefix: String) -> void:
	_press(_find_button(current_scene.get_node("%Choices"), prefix), prefix)


func _play(card_name: String) -> void:
	_press(_find_button(current_scene.get_node("Combat/%HandCards"), card_name + "\n"), card_name)


func _combat_action(expected_label: String) -> void:
	var button: Button = current_scene.get_node_or_null("Combat/%EndTurnButton")
	_check(button != null and button.text == expected_label, "%s action is available" % expected_label)
	if button != null and button.text == expected_label:
		_press(button, expected_label)


func _combat_text(path: String) -> String:
	return _text("Combat/" + path)


func _text(path: String) -> String:
	var node := current_scene.get_node(path)
	return node.text


func _find_button(container: Node, prefix: String) -> Button:
	for button: Button in container.get_children():
		if button.text.begins_with(prefix):
			return button
	return null


func _press(button: Button, context: String) -> void:
	_check(button != null and not button.disabled, "can click %s" % context)
	if button != null and not button.disabled:
		button.pressed.emit()


func _check(condition: bool, context: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(context)


func _on_timeout() -> void:
	push_error("The run UI test timed out waiting for a scene transition.")
	quit(1)
