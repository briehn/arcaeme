extends SceneTree

const CardData = preload("res://scripts/combat/card_data.gd")
const CombatView = preload("res://scripts/combat.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const RuneCanvas = preload("res://scripts/ui/rune_canvas.gd")
const SpellDrawingPanel = preload("res://scripts/ui/spell_drawing_panel.gd")
const MENU = preload("res://scenes/main.tscn")
const COMBAT = preload("res://scenes/combat.tscn")
const ENCOUNTER = preload("res://resources/prototype/enemies/two_slimes.tres")
const BLOCK = preload("res://resources/prototype/cards/basic_block.tres")
const SETTINGS = preload("res://resources/prototype/spell_drawing_settings.tres")
const TOGGLE_ACTION := &"toggle_rune_stroke"
const HOLD := RuneCanvas.DrawingMode.HOLD
const TOGGLE := RuneCanvas.DrawingMode.TOGGLE
const VIEWPORT_SIZES := [Vector2i(960, 540), Vector2i(1024, 576), Vector2i(1280, 720), Vector2i(1920, 1080)]

var _viewport: SubViewport
var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_check(RuneCanvas.session_input_mode == HOLD, "the first session defaults to Hold Left Click")
	var x_event := InputEventKey.new()
	x_event.keycode = KEY_X
	_check(InputMap.has_action(TOGGLE_ACTION) and InputMap.action_has_event(TOGGLE_ACTION, x_event),
		"Toggle Drawing uses a rebindable Godot action with X as the default")
	for viewport_size in VIEWPORT_SIZES:
		_viewport = SubViewport.new()
		_viewport.size = viewport_size
		root.add_child(_viewport)
		await _test_menu()
		await _test_cast(HOLD)
		await _test_cast(TOGGLE)
		await _test_interruption()
		await _test_timeout(HOLD)
		await _test_timeout(TOGGLE)
		if viewport_size == VIEWPORT_SIZES[0]:
			await _test_rebind()
		_viewport.queue_free()
		await process_frame
	RuneCanvas.session_input_mode = HOLD
	print("Drawing input modes: %d checks at %d viewport sizes, %d failures." % [
		_checks, VIEWPORT_SIZES.size(), _failures])
	quit(int(_failures > 0))


func _test_menu() -> void:
	RuneCanvas.session_input_mode = HOLD
	var menu := MENU.instantiate()
	_viewport.add_child(menu)
	await _settle()
	await _click(menu.get_node("%OpenPrototypeTools"))
	var drawing := menu.get_node("%SpellDrawing") as CheckBox
	await _click(drawing)
	var option := menu.get_node("%DrawingInputMode") as OptionButton
	_check(option.get_selected_id() == HOLD and not option.disabled,
		"Prototype Tools publishes the selected drawing mode")
	var toggle_index := option.get_item_index(TOGGLE)
	option.select(toggle_index)
	option.item_selected.emit(toggle_index)
	menu.queue_free()
	await _settle()

	menu = MENU.instantiate()
	_viewport.add_child(menu)
	await _settle()
	await _click(menu.get_node("%OpenPrototypeTools"))
	option = menu.get_node("%DrawingInputMode") as OptionButton
	_check(RuneCanvas.session_input_mode == TOGGLE and option.get_selected_id() == TOGGLE,
		"the choice survives a return to a new main menu instance")
	menu.queue_free()
	await _settle()


func _test_cast(mode: int) -> void:
	var view := await _open_view(mode)
	var panel := _panel(view)
	var canvas := _canvas(view)
	var actor := view._state.players[CombatView.PLAYER_ID]
	var stroke: PackedVector2Array = canvas._guide[0]
	var points := _viewport_points(canvas, stroke)
	var outside := Vector2(2, 2)
	_check(_fits(canvas) and _fits(panel.get_node("%SubmitButton")), "canvas and actions fit in mode %d" % mode)
	_check(canvas.mouse_default_cursor_shape == Control.CURSOR_ARROW and actor.mana == 3,
		"the normal pointer, unchanged Mana and ready clock apply in mode %d" % mode)
	_motion(points[0])
	_check(canvas._brush_overlay.visible and canvas.completed_strokes(true).is_empty(),
		"hover still previews the footprint without capturing ink")
	_motion(outside)
	_tap(KEY_X)
	_motion(points[0])
	_check(canvas.completed_strokes(true).is_empty() and canvas._current.is_empty(),
		"X outside the canvas cannot arm a stroke on reentry")
	if mode == HOLD:
		_tap(KEY_X)
		_motion(points[1])
		_check(canvas._current.is_empty() and canvas.completed_strokes(true).is_empty(),
			"X and motion do not draw in Hold Left Click")
		_motion(points[0])
		_button(points[0], true)
		_motion(points[1], MOUSE_BUTTON_MASK_LEFT)
		_motion(points[2], MOUSE_BUTTON_MASK_LEFT)
		_check(not canvas.has_completed_strokes() and canvas.completed_strokes(true).size() == 1,
			"held mouse capture has meaningful ink before button release")
		_button(points[2], false)
	else:
		_button(points[0], true)
		_motion(points[1], MOUSE_BUTTON_MASK_LEFT)
		_button(points[1], false)
		_check(canvas.completed_strokes(true).is_empty() and canvas._current.is_empty(),
			"click and drag do not capture in Toggle Drawing")
		_motion(points[0])
		_key(KEY_X, true)
		_key(KEY_X, true, true)
		_key(KEY_X, false)
		_motion(points[1])
		_motion(points[2])
		_check(not canvas.has_completed_strokes() and canvas.completed_strokes(true).size() == 1,
			"zero-button motion makes ink between X presses and repeat does not end the stroke")
		_tap(KEY_X)
	_check(canvas.has_completed_strokes() and canvas.completed_strokes().size() == 1
		and _same_path(canvas.completed_strokes()[0], canvas._guide_fit * stroke),
		"mode %d feeds the projected guide's normalized path to recognition" % mode)
	await _click(panel.get_node("%SubmitButton"))
	_check(not panel.visible and actor.mana == 2 and actor.block == 6 and actor.hand.is_empty()
		and actor.discard_pile.size() == 1 and view._state.action_history.size() == 1
		and view._state.action_history.back().spell_power_percent == 110,
		"exact casting in mode %d gives the same quality and exactly-once payment" % mode)
	_tap(KEY_X)
	_check(view._state.action_history.size() == 1, "X while the panel is closed cannot recast")
	await _close_view(view)


func _test_interruption() -> void:
	var view := await _open_view(TOGGLE)
	var panel := _panel(view)
	var canvas := _canvas(view)
	var stroke: PackedVector2Array = canvas._guide[0]
	var points := _viewport_points(canvas, stroke)
	var actor := view._state.players[CombatView.PLAYER_ID]
	var deadline: int = panel.get("_deadline_ms")
	_motion(points[0])
	_tap(KEY_X)
	_motion(points[1])
	panel.set_input_mode(HOLD)
	_check(canvas.completed_strokes().size() == 1 and canvas._current.is_empty()
		and panel.get("_deadline_ms") == deadline, "mode change safely ends active ink and keeps the original deadline")
	await _click(panel.get_node("%ClearButton"))
	_check(canvas.completed_strokes(true).is_empty() and canvas._current.is_empty(),
		"Clear remains usable after a mode change")

	panel.set_input_mode(TOGGLE)
	await _settle()
	points = _viewport_points(canvas, stroke)
	_motion(points[0])
	_tap(KEY_X)
	_motion(points[1])
	_motion(Vector2(2, 2))
	var finished := canvas.completed_strokes()
	var endpoint := finished[0][-1] if finished.size() == 1 else Vector2.INF
	var expected_endpoint := canvas._guide_fit * stroke[1]
	_check(finished.size() == 1 and canvas._current.is_empty()
		and not canvas._brush_overlay.visible
		and endpoint.distance_to(expected_endpoint) < 0.00005,
		"leaving the surface stops at the last in-bounds sample (%s, expected %s)" % [endpoint, expected_endpoint])
	_motion(points[2])
	_check(canvas._current.is_empty() and canvas.completed_strokes().size() == 1,
		"reentry never silently starts another stroke")
	_tap(KEY_X)
	_motion(points[1])
	_tap(KEY_ESCAPE)
	await _settle()
	_check(not panel.visible and canvas.completed_strokes(true).is_empty() and canvas._current.is_empty()
		and actor.mana == 3 and actor.discard_pile.is_empty() and view._state.action_history.is_empty(),
		"Cancel discards both stored and active ink without resolving the card")
	await _close_view(view)


func _test_timeout(mode: int) -> void:
	var view := await _open_view(mode, 700)
	var panel := _panel(view)
	var canvas := _canvas(view)
	var actor := view._state.players[CombatView.PLAYER_ID]
	var points := _viewport_points(canvas, canvas._guide[0])
	_motion(points[0])
	if mode == HOLD:
		_button(points[0], true)
	else:
		_tap(KEY_X)
	var mask := MOUSE_BUTTON_MASK_LEFT if mode == HOLD else 0
	_motion(points[1], mask)
	_motion(points[2], mask)
	_check(not canvas.has_completed_strokes() and canvas.completed_strokes(true).size() == 1,
		"mode %d has active ink when the timer is approaching expiry" % mode)
	var watchdog := Time.get_ticks_msec() + 2500
	while panel.visible and Time.get_ticks_msec() < watchdog:
		await process_frame
	_check(not panel.visible and canvas.completed_strokes(true).is_empty() and canvas._current.is_empty()
		and actor.mana == 2 and actor.block == 6 and actor.discard_pile.size() == 1
		and view._state.action_history.size() == 1,
		"mode %d preserves the active stroke at timeout and resolves it once" % mode)
	if mode == HOLD:
		_button(points[2], false)
	else:
		_tap(KEY_X)
	_check(actor.mana == 2 and view._state.action_history.size() == 1,
		"late stroke termination after timeout cannot spend Mana again")
	await _close_view(view)


func _test_rebind() -> void:
	var original := InputMap.action_get_events(TOGGLE_ACTION)
	InputMap.action_erase_events(TOGGLE_ACTION)
	var replacement := InputEventKey.new()
	replacement.keycode = KEY_Y
	InputMap.action_add_event(TOGGLE_ACTION, replacement)
	var view := await _open_view(TOGGLE)
	var canvas := _canvas(view)
	var points := _viewport_points(canvas, canvas._guide[0])
	_motion(points[0])
	_tap(KEY_X)
	_motion(points[1])
	_check(canvas._current.is_empty(), "an old key no longer arms the stroke after rebinding")
	_motion(points[0])
	_tap(KEY_Y)
	_motion(points[1])
	_tap(KEY_Y)
	_check(canvas.completed_strokes().size() == 1, "a remapped action can start and finish a stroke")
	await _close_view(view)
	InputMap.action_erase_events(TOGGLE_ACTION)
	for event in original:
		InputMap.action_add_event(TOGGLE_ACTION, event)


func _open_view(mode: int, duration := 10000) -> CombatView:
	RuneCanvas.session_input_mode = mode
	var encounter: EncounterData = ENCOUNTER.duplicate()
	var card: CardData = BLOCK.duplicate()
	card.rune_template = BLOCK.rune_template.duplicate()
	card.rune_template.cast_time_ms = duration
	encounter.test_deck = [card]
	var view := COMBAT.instantiate() as CombatView
	view.encounter = encounter
	view.spell_drawing = SETTINGS
	_viewport.add_child(view)
	await _settle()
	await _click(view.hand_cards.get_child(0) as Button)
	_check(_panel(view).visible and _canvas(view)._drawing_enabled,
		"the real combat view opens a timed rune panel")
	return view


func _close_view(view: CombatView) -> void:
	view.queue_free()
	await _settle()


func _panel(view: CombatView) -> SpellDrawingPanel:
	return view.get_node("SpellDrawingPanel") as SpellDrawingPanel


func _canvas(view: CombatView) -> RuneCanvas:
	return _panel(view).get_node("%RuneCanvas") as RuneCanvas


func _viewport_points(canvas: RuneCanvas, path: PackedVector2Array) -> PackedVector2Array:
	return canvas.get_global_transform_with_canvas() * canvas._local_points(path)


func _same_path(first: PackedVector2Array, second: PackedVector2Array) -> bool:
	if first.size() != second.size():
		return false
	for index in first.size():
		if not first[index].is_equal_approx(second[index]):
			return false
	return true


func _fits(control: Control) -> bool:
	var rect := control.get_global_rect()
	if not control.is_visible_in_tree() or not Rect2(Vector2.ZERO, Vector2(_viewport.size)).encloses(rect):
		return false
	var parent := control.get_parent()
	while parent is Control:
		if parent.clip_contents and not parent.get_global_rect().encloses(rect):
			return false
		parent = parent.get_parent()
	return true


func _click(control: Control) -> void:
	var parent := control.get_parent()
	while parent is Control and not _fits(control):
		if parent is ScrollContainer:
			parent.ensure_control_visible(control)
			await _settle()
		parent = parent.get_parent()
	var position := control.get_global_rect().get_center()
	_button(position, true)
	_button(position, false)
	await _settle()


func _motion(position: Vector2, mask := 0) -> void:
	var event := InputEventMouseMotion.new()
	event.button_mask = mask
	event.position = position
	event.global_position = position
	_viewport.push_input(event, true)


func _button(position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = position
	event.global_position = position
	event.pressed = pressed
	_viewport.push_input(event, true)


func _tap(key: Key) -> void:
	_key(key, true)
	_key(key, false)


func _key(key: Key, pressed: bool, echo := false) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.echo = echo
	event.pressed = pressed
	_viewport.push_input(event, true)


func _settle() -> void:
	await process_frame
	await process_frame
	await process_frame


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("%s: %s" % [_viewport.size if is_instance_valid(_viewport) else "Startup", message])
