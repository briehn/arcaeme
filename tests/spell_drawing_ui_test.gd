extends SceneTree

const CombatView = preload("res://scripts/combat.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const RuneCanvas = preload("res://scripts/ui/rune_canvas.gd")
const MENU = preload("res://scenes/main.tscn")
const SOLO = preload("res://scenes/combat.tscn")
const LOCAL = preload("res://scenes/local_coop.tscn")
const TWO_SLIMES = preload("res://resources/prototype/enemies/two_slimes.tres")
const DRAWING_SETTINGS = preload("res://resources/prototype/spell_drawing_settings.tres")
const ASTRA = preload("res://resources/prototype/cards/expansion/astral_salvo.tres")
const BLOCK = preload("res://resources/prototype/cards/basic_block.tres")
const BOOSTER = preload("res://resources/prototype/cards/spell_ink_booster.tres")
const FIRST_TARGET := &"slime_1"
const SECOND_TARGET := &"slime_2"
const VIEWPORT_SIZES := [Vector2i(960, 540), Vector2i(1024, 576), Vector2i(1280, 720), Vector2i(1920, 1080)]

var _viewport: SubViewport
var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for viewport_size in VIEWPORT_SIZES:
		_viewport = SubViewport.new()
		_viewport.size = viewport_size
		root.add_child(_viewport)
		await _test_menu()
		await _test_solo()
		await _test_local()
		await _test_bypass()
		_viewport.queue_free()
		await process_frame
	print("Spell drawing UI: %d checks at %d viewport sizes, %d failures." % [_checks, VIEWPORT_SIZES.size(), _failures])
	quit(int(_failures != 0))


func _test_menu() -> void:
	var menu := MENU.instantiate()
	_viewport.add_child(menu)
	await _settle()
	await _click(menu.get_node("%OpenPrototypeTools"))
	var drawing := menu.get_node("%SpellDrawing") as CheckBox
	var bypass := menu.get_node("%SpellDrawingBypass") as CheckBox
	_check(not drawing.button_pressed and bypass.disabled and not bypass.button_pressed,
		"spell drawing and its bypass start off")
	await _click(drawing)
	_check(drawing.button_pressed and not bypass.disabled, "opt-in enables the testing bypass")
	await _click(bypass)
	_check(bypass.button_pressed, "testing bypass can be selected")
	await _click(drawing)
	_check(bypass.disabled and not bypass.button_pressed, "disabling spell drawing clears the bypass")
	menu.queue_free()
	await _settle()


func _test_solo() -> void:
	var combat := await _open_combat(SOLO)
	var state := combat._state
	var player = state.players[CombatView.PLAYER_ID]
	var panel := combat.get_node("SpellDrawingPanel") as Control
	var canvas := panel.get_node("%RuneCanvas") as RuneCanvas
	var cast_button := panel.get_node("%SubmitButton") as Button
	var guide_label := panel.get_node("%RuneName") as Label
	var end_turn := combat.get_node("%EndTurnButton") as Button

	await _click(_card(combat, "Basic Strike"))
	_check(not panel.visible and combat.get_node("%TargetLabel").visible,
		"attack selects an enemy before opening the rune overlay")
	await _click(combat._enemy_buttons[SECOND_TARGET])
	_check(panel.visible and guide_label.text == "Strike Rune" and cast_button.disabled and end_turn.disabled,
		"target opens the rune overlay with timer, blank cast disabled, and End Turn locked")
	_check(player.mana == 3 and player.hand.size() == 5 and state.action_history.is_empty(),
		"showing the target-specific cast spends no Mana and removes no card")
	_check(_fully_visible(canvas) and absf(canvas.size.aspect() - 1.0) < 0.01
		and _fully_visible(panel.get_node("%TimeLabel")) and _fully_visible(cast_button),
		"the square canvas, timer, and Cast control fit")

	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	_viewport.push_input(escape, true)
	escape.pressed = false
	_viewport.push_input(escape, true)
	await _settle()
	_check(not panel.visible and not end_turn.disabled and "canceled" in combat.spell_feedback.text,
		"Escape closes the modal, restores combat, and displays canceled feedback")
	_check(player.mana == 3 and player.hand.size() == 5 and state.enemy_state(SECOND_TARGET).hp == 22,
		"cancel retains the card, Mana, and target HP")

	await _click(_card(combat, "Spell Ink Booster"))
	_check(not panel.visible and player.mana == 2 and player.hand.size() == 4
		and "extra stroke" in combat.spell_feedback.text, "Booster resolves instantly and primes an extra stroke")
	await _select_salvo(combat)
	_check(panel.visible and "extra stroke" in guide_label.text and canvas._guide.size() == 3
		and canvas._guide[-1] == BOOSTER.spell_booster_stroke, "the boosted Salvo visibly includes its third stroke")
	_draw_stroke(canvas, ASTRA.rune_template.strokes[0])
	await _click(cast_button)
	_check(not panel.visible and "incomplete" in combat.spell_feedback.text and player.mana == 2
		and player.hand.size() == 4, "partial Salvo reports incomplete and retains its card and Mana")
	await _select_salvo(combat)
	_check(panel.visible and "extra stroke" in guide_label.text, "the extra stroke survives an incomplete cast")
	for stroke in ASTRA.rune_template.strokes:
		_draw_stroke(canvas, stroke)
	_draw_stroke(canvas, BOOSTER.spell_booster_stroke)
	await _click(cast_button)
	_check(not panel.visible and "120% base power" in combat.spell_feedback.text, "the mouse-drawn boosted Salvo succeeds")
	_check(state.enemy_state(FIRST_TARGET).hp == 18 and state.enemy_state(SECOND_TARGET).hp == 6,
		"both 8-damage hits resolve against only the selected enemy")
	_check(player.mana == 0 and player.hand.size() == 3 and player.discard_pile.size() == 2
		and player.spell_booster_stroke.is_empty() and state.action_history.size() == 2,
		"successful cast spends Mana, moves its card, and consumes the booster once")
	combat.queue_free()
	await _settle()


func _test_local() -> void:
	var combat := await _open_combat(LOCAL)
	var state := combat._state
	var player_one = state.players[&"Battle Mage 1"]
	var player_two = state.players[&"Battle Mage 2"]
	var panel := combat.get_node("SpellDrawingPanel") as Control
	await _click(_card(combat, "Spell Ink Booster"))
	var selector := combat.get_node("%PlayerSelector")
	await _click(selector.get_child(1))
	await _click(_card(combat, "Basic Block"))
	_check(panel.visible and (panel.get_node("%RuneName") as Label).text == "Block Rune",
		"Mage 2 sees their own rune without Mage 1's booster")
	_draw_stroke(panel.get_node("%RuneCanvas"), BLOCK.rune_template.strokes[0])
	await _click(panel.get_node("%SubmitButton"))
	_check(player_two.block == 5 and player_two.mana == 2 and player_one.block == 0
		and not player_one.spell_booster_stroke.is_empty(), "Block and booster state stay with their respective Mages")
	await _click(combat.get_node("%EndTurnButton"))
	_check(player_two.ended_turn and not player_one.ended_turn and state.round_number == 1,
		"the local Mage can Ready normally after casting")
	combat.queue_free()
	await _settle()


func _test_bypass() -> void:
	var combat := await _open_combat(SOLO, true)
	var player = combat._state.players[CombatView.PLAYER_ID]
	await _click(_card(combat, "Basic Block"))
	_check(not combat.has_node("SpellDrawingPanel") and player.block == 5 and player.mana == 2
		and "full power" in combat.spell_feedback.text, "testing bypass resolves at full base power without the overlay")
	combat.queue_free()
	await _settle()


func _open_combat(scene: PackedScene, bypass := false) -> CombatView:
	var combat := scene.instantiate() as CombatView
	var fixture: EncounterData = TWO_SLIMES.duplicate()
	fixture.test_deck = DRAWING_SETTINGS.test_deck.duplicate()
	combat.encounter = fixture
	combat.spell_drawing = DRAWING_SETTINGS
	combat.bypass_drawing = bypass
	_viewport.add_child(combat)
	await _settle()
	return combat


func _select_salvo(combat: CombatView) -> void:
	await _click(_card(combat, "Astral Salvo"))
	await _click(combat._enemy_buttons[SECOND_TARGET])


func _card(combat: CombatView, title: String) -> Button:
	for button: Button in combat.hand_cards.get_children():
		if button.text.begins_with(title + "\n"):
			return button
	return null


func _draw_stroke(canvas: RuneCanvas, stroke: PackedVector2Array) -> void:
	var points := canvas._local_points(stroke)
	var transform := canvas.get_global_transform_with_canvas()
	_mouse_button(transform * points[0], true)
	for index in range(1, points.size()):
		var event := InputEventMouseMotion.new()
		event.button_mask = MOUSE_BUTTON_MASK_LEFT
		event.position = transform * points[index]
		event.global_position = event.position
		_viewport.push_input(event, true)
	_mouse_button(transform * points[-1], false)


func _mouse_button(position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = position
	event.global_position = position
	event.pressed = pressed
	_viewport.push_input(event, true)


func _click(control: Control) -> void:
	if control == null:
		_check(false, "missing control")
		return
	var parent := control.get_parent()
	while parent is Control and not _fully_visible(control):
		if parent is ScrollContainer:
			parent.ensure_control_visible(control)
			await _settle()
		parent = parent.get_parent()
	_check(_fully_visible(control), "%s is reachable" % control.name)
	var position := control.get_global_rect().get_center()
	_mouse_button(position, true)
	_mouse_button(position, false)
	await _settle()


func _fully_visible(control: Control) -> bool:
	var rect := control.get_global_rect()
	if not control.is_visible_in_tree() or not rect.has_area() or not Rect2(Vector2.ZERO, Vector2(_viewport.size)).encloses(rect):
		return false
	var parent := control.get_parent()
	while parent is Control:
		if parent.clip_contents and not parent.get_global_rect().encloses(rect):
			return false
		parent = parent.get_parent()
	return true


func _settle() -> void:
	for frame in 5:
		await process_frame


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("%s — %s" % [_viewport.size, message])
