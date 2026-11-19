extends SceneTree

const CombatState = preload("res://scripts/combat/combat_state.gd")
const NetworkSession = preload("res://scripts/network/network_coop_session.gd")
const ViewSnapshot = preload("res://scripts/combat/combat_view_snapshot.gd")
const MAIN = preload("res://scenes/main.tscn")
const NETWORK = preload("res://scenes/network_coop.tscn")
const SOLO = preload("res://scenes/combat.tscn")
const LOCAL = preload("res://scenes/local_coop.tscn")
const STATUS = preload("res://scenes/status_playtest.tscn")
const RUN = preload("res://scenes/prototype_run.tscn")
const ENCOUNTER = preload("res://resources/prototype/status_playtest/encounter.tres")
const REVERSAL = preload("res://resources/prototype/cards/arcane_reversal.tres")
const NAMES: Array[StringName] = [&"Battle Mage 1", &"Battle Mage 2", &"Battle Mage 3", &"Battle Mage 4"]
const VIEWPORT_SIZES := [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(960, 540)]

var _viewport: SubViewport
var _size: Vector2i
var _checks := 0
var _failures := 0
var _end_requests := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for viewport_size in VIEWPORT_SIZES:
		_size = viewport_size
		var initial_checks := _checks
		var initial_failures := _failures
		_viewport = SubViewport.new()
		_viewport.size = _size
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(_viewport)
		await _test_menu()
		await _test_combat(SOLO, "solo", false)
		await _test_combat(LOCAL, "local co-op", false)
		await _test_combat(STATUS, "solo status", true)
		await _test_solo_run()
		await _test_network()
		_viewport.queue_free()
		await process_frame
		print("%dx%d layout: %d checks, %d failures." %
			[_size.x, _size.y, _checks - initial_checks, _failures - initial_failures])
	print("Combat layout: %d checks, %d failures." % [_checks, _failures])
	quit(1 if _failures else 0)


func _test_menu() -> void:
	var menu := await _open(MAIN)
	for button in menu.find_children("*", "Button", true, false):
		_check_control(button, "main menu")
	await _close(menu)


func _test_combat(scene: PackedScene, context: String, status_mode: bool) -> void:
	var combat := await _open(scene)
	await _check_combat(combat, context)
	var end := _control(combat, "%EndTurnButton") as Button
	var initial_turn: String = (_control(combat, "%TurnLabel") as Label).text
	var initial_hp := (_control(combat, "%PlayerLabel") as Label).text
	if status_mode:
		var poison := _card(combat, "Test Toxic Spark")
		if poison != null and await _reach(poison):
			_click(poison)
			await _settle()
		_check("Poison 4" in (_control(combat, "%EnemyLabel") as Label).text, "solo status card can be clicked")
	if await _reach(end):
		_click(end)
		await _settle()
		var turn: Label = _control(combat, "%TurnLabel")
		var players: Label = _control(combat, "%PlayerLabel")
		_check(turn.text != initial_turn or players.text != initial_hp, "%s End Turn handles viewport input" % context)
	if status_mode:
		_check("Poison 1" in (_control(combat, "%PlayerLabel") as Label).text and
			"Burning 3" in (_control(combat, "%PlayerLabel") as Label).text, "solo status effects remain readable after End Turn")
	await _close(combat)


func _test_solo_run() -> void:
	var run := await _open(RUN)
	var choices := _control(run, "%Choices")
	for choice in choices.get_children():
		_check_control(choice, "solo run route")
	_check_control(_control(run, "%RunBackButton"), "solo run route")
	if await _reach(choices.get_child(0) as Control):
		_click(choices.get_child(0) as Control)
		await _settle()
		var combat := run.get_node("Combat") as Control
		await _check_combat(combat, "solo run fight")
	await _close(run)


func _test_network() -> void:
	var scene := await _open(NETWORK)
	var session: NetworkSession = scene.get_node("Session")
	var short_run := _control(scene, "%ShortRun") as CheckBox
	var status_playtest := _control(scene, "%StatusPlaytest") as CheckBox
	var party := _control(scene, "%PartySize") as OptionButton
	var port := _control(scene, "%Port") as SpinBox
	_check(port.editable and not party.disabled and party.item_count == 3, "lobby port and party size are usable")
	for path in ["%Port", "%PartySize", "%ShortRun", "%StatusPlaytest", "%HostButton", "%JoinButton", "%LeaveButton"]:
		_check_control(_control(scene, path), "network lobby")
	if await _reach(status_playtest):
		_click(status_playtest)
		await _settle()
	_check(session.encounter == ENCOUNTER and status_playtest.button_pressed, "status option handles viewport input")
	if await _reach(short_run):
		_click(short_run)
		await _settle()
	_check(status_playtest.disabled and not status_playtest.button_pressed and "Short Run" in
		(_control(scene, "%HostButton") as Button).text, "short-run option updates lobby mode and status availability")

	var combat := _control(scene, "%CombatSlot").get_node("Combat") as Control
	session.party_size = 4
	session.local_player = String(NAMES[0])
	session.connected_players = PackedStringArray(NAMES)
	session.message = "Host · Battle Mage 1 · Connected"
	session.status = NetworkSession.Status.ACTIVE
	var state := CombatState.new(ENCOUNTER, ENCOUNTER.shuffle_seed, NAMES)
	state.enemy_poison = 7
	state.enemy_burning = 3
	for player in state.players.values():
		player.poison = 1
		player.burning = 3
	var snapshot := ViewSnapshot.build(state, ENCOUNTER, NAMES[0])
	session.snapshot = snapshot
	session.changed.emit()
	await _settle()
	_check("Poison 7" in (_control(combat, "%EnemyLabel") as Label).text and
		"Burning 3" in (_control(combat, "%PlayerLabel") as Label).text, "four-player combat shows status counters")
	_check_control(_control(scene, "%ConnectionStatus"), "active network")
	_check_control(_control(scene, "%PartyRoster"), "active network")
	_check_control(_control(scene, "%LeaveButton"), "active network")
	if _size.x >= 1280 and _size.y >= 720:
		for card in _control(combat, "%HandCards").get_children():
			_check(_fully_visible(card), "four-player status opening hand shows %s without scrolling (rect %s)" %
				[card.text.get_slice("\n", 0), card.get_global_rect()])
	await _check_combat(combat, "four-player network status")
	var end := _control(combat, "%EndTurnButton") as Button
	combat.network_end_turn_requested.disconnect(session.submit_end_turn)
	combat.network_end_turn_requested.connect(func(): _end_requests += 1)
	var previous_requests := _end_requests
	if await _reach(end):
		_click(end)
		await _settle()
	_check(_end_requests == previous_requests + 1, "network End Turn emits its command from viewport input")
	await _test_long_hand(session, combat, snapshot)

	session.snapshot = _reward_snapshot(snapshot)
	session.changed.emit()
	await _settle()
	_check(not combat.is_visible_in_tree(), "reward panels replace network combat")
	_check_control(_control(scene, "%RunStage"), "network reward")
	_check_control(_control(scene, "%RewardProgress"), "network reward")
	_check_control(_control(scene, "%SkipReward"), "network reward")
	for choice in _control(scene, "%RewardChoices").get_children():
		_check(await _reach(choice), "network reward %s is reachable" % choice.text.get_slice("\n", 0))
	_check_control(_control(scene, "%SkipReward"), "network reward after choice navigation")
	await _close(scene)


func _test_long_hand(session: NetworkSession, combat: Control, snapshot: Dictionary) -> void:
	var expanded := snapshot.duplicate(true)
	for index in 4:
		expanded.hand.append({"copy": 100 + index, "id": String(REVERSAL.id), "name": REVERSAL.display_name,
			"cost": REVERSAL.mana_cost, "description": REVERSAL.description(), "approval": REVERSAL.approval_status,
			"attack": REVERSAL.is_attack, "playable": true})
	session.snapshot = expanded
	session.changed.emit()
	await _settle()
	var hand := _control(combat, "%HandCards")
	var last := hand.get_child(hand.get_child_count() - 1) as Button
	_check(last.text.begins_with("Arcane Reversal") and "lose 6 Block to deal 6 additional damage" in last.text,
		"expanded hand includes the complete Arcane Reversal rules text")
	last.grab_focus()
	await _settle()
	_check(last.has_focus() and _fully_visible(last), "focusing the last card scrolls its full button into view (rect %s)" %
		last.get_global_rect())
	_check_card_text(last)
	_check_control(_control(combat, "%EndTurnButton"), "expanded hand after last-card focus")


func _reward_snapshot(snapshot: Dictionary) -> Dictionary:
	var reward := snapshot.duplicate()
	var options: Array[Dictionary] = []
	for card in preload("res://resources/prototype/battle_mage_run.tres").reward_candidates:
		options.append({"id": String(card.id), "name": card.display_name, "cost": card.mana_cost,
			"description": card.description()})
	reward.merge({"run_stage": "reward", "encounter_id": 1, "reward_ready": 1, "reward_submitted": false,
		"reward_options": options})
	return reward


func _check_combat(combat: Control, context: String) -> void:
	_check_control(_control(combat, "%EndTurnButton"), context)
	for path in ["%TurnLabel", "%PlayerLabel", "%EnemyLabel", "%CardsLabel"]:
		var label := _control(combat, path)
		_check(await _reach(label), "%s %s is readable (rect %s)" % [context, label.name, label.get_global_rect()])
	var hand := _control(combat, "%HandCards")
	_check(hand.get_child_count() == 5, "%s renders the full five-card opening hand" % context)
	for card in hand.get_children():
		_check(await _reach(card), "%s card %s is reachable (rect %s)" % [context, card.text.get_slice("\n", 0), card.get_global_rect()])
	_check_control(_control(combat, "%EndTurnButton"), context + " after hand navigation")


func _check_card_text(button: Button) -> void:
	var style := button.get_theme_stylebox("normal")
	var padding := style.get_minimum_size()
	var paragraph := TextParagraph.new()
	paragraph.width = button.size.x - padding.x
	paragraph.break_flags = TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE
	paragraph.add_string(button.text, button.get_theme_font("font"), button.get_theme_font_size("font_size"))
	var text_height := paragraph.get_size().y
	_check(text_height <= button.size.y - padding.y + 1.0,
		"Arcane Reversal's wrapped text fits (%0.1f of %0.1f usable pixels)" % [text_height, button.size.y - padding.y])


func _control(scene: Node, path: NodePath) -> Control:
	return scene.get_node(path) as Control


func _card(combat: Node, name_prefix: String) -> Button:
	for card in _control(combat, "%HandCards").get_children():
		if card.text.begins_with(name_prefix):
			return card
	return null


func _open(scene: PackedScene) -> Control:
	var instance := scene.instantiate() as Control
	_viewport.add_child(instance)
	await _settle()
	return instance


func _close(scene: Control) -> void:
	scene.queue_free()
	await _settle()


func _settle() -> void:
	for frame in 5:
		await process_frame


func _click(control: Control) -> void:
	var position := control.get_global_rect().get_center()
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = position
	event.global_position = position
	event.pressed = true
	_viewport.push_input(event, true)
	event.pressed = false
	_viewport.push_input(event, true)


func _reach(control: Control) -> bool:
	var parent := control.get_parent()
	while parent is Control and not _fully_visible(control):
		if parent is ScrollContainer:
			parent.ensure_control_visible(control)
			await _settle()
		parent = parent.get_parent()
	return _fully_visible(control)


func _fully_visible(control: Control) -> bool:
	var rect := control.get_global_rect()
	if not control.is_visible_in_tree() or not rect.has_area() or not Rect2(Vector2.ZERO, Vector2(_size)).encloses(rect):
		return false
	var parent := control.get_parent()
	while parent is Control:
		if parent.clip_contents and not parent.get_global_rect().encloses(rect):
			return false
		parent = parent.get_parent()
	return true


func _check_control(control: Control, context: String) -> void:
	var enabled: bool = not (control is Button and (control as Button).disabled)
	_check(_fully_visible(control) and enabled, "%s %s fits viewport (rect %s)" %
		[context, control.name, control.get_global_rect()])


func _check(condition: bool, context: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("%dx%d %s" % [_size.x, _size.y, context])
