extends SceneTree

const PortalChoiceButton = preload("res://scripts/ui/portal_choice_button.gd")
const SIZES := [Vector2i(960, 540), Vector2i(1024, 576), Vector2i(1280, 720), Vector2i(1920, 1080)]
const CATEGORIES := ["Normal Encounter", "Elite Encounter", "Boss Encounter"]
const FILENAMES := ["portal_normal.png", "portal_elite.png", "portal_boss.png"]

var _checks := 0
var _failures := 0
var _clicked := ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for resolution in SIZES:
		for count in range(1, 4):
			await _check_row(resolution, count)
	print("Physical portal UI: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _check_row(resolution: Vector2i, count: int) -> void:
	var viewport := SubViewport.new()
	viewport.size = resolution
	root.add_child(viewport)
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	viewport.add_child(row)
	var start := CATEGORIES.size() - count
	for index in range(start, CATEGORIES.size()):
		var choice := PortalChoiceButton.make({"id": str(index), "type": CATEGORIES[index],
			"branches": [{"type": "Normal Encounter"}] if index < 2 else []})
		choice.pressed.connect(func(): _clicked = str(index))
		row.add_child(choice)
		PortalChoiceButton.size_to_battlefield(choice, resolution.x)
		var art := choice.get_node("PortalArt") as TextureRect
		_check(art.texture != null and art.texture.resource_path == "res://assets/portals/" + FILENAMES[index],
			"%s uses its handmade portal PNG" % CATEGORIES[index])
		var caption: String = "Next portals: Normal Encounter" if index < 2 else "No further portals"
		_check(choice.text == "%s\n%s" % [CATEGORIES[index], caption] and choice.tooltip_text.is_empty(),
			"portal labels stay category-only")
	for _frame in 4:
		await process_frame
	var previous_end := 0.0
	for button: Button in row.get_children():
		var box := button.get_global_rect()
		_check(box.position.x >= previous_end and Rect2(Vector2.ZERO, Vector2(resolution)).encloses(box),
			"%d portal choices fit %s without overlap" % [count, resolution])
		previous_end = box.end.x
	var boss := row.get_child(count - 1) as Button
	var first := row.get_child(0) as Button
	_clicked = ""
	boss.grab_focus()
	_check(boss.get_theme_stylebox("focus") is StyleBoxEmpty and not _focus_brackets(boss).visible
		and not boss.has_node("PortalHalo"), "initial focus and default artwork have no ground decoration")
	for button: Button in row.get_children():
		_move_to(viewport, _art(button).get_global_rect().get_center())
		_check(_art(button).self_modulate != Color.WHITE and _clicked.is_empty()
			and (button.get_node("PortalVoters") as Label).text.is_empty(), "hover highlights only the artwork")
		for other: Button in row.get_children():
			_check(not _focus_brackets(other).visible and (other == button or _art(other).self_modulate == Color.WHITE),
				"moving the mouse leaves no focus marking or emphasis on another portal")
	_check(boss.has_focus(), "mouse movement preserves the focus target for keyboard navigation")
	_send_key(viewport, KEY_LEFT)
	var expected := row.get_child(maxi(0, count - 2)) as Button
	_check(expected.has_focus() and _focus_brackets(expected).visible and _art(boss).self_modulate == Color.WHITE,
		"Left moves focus and shows only the focused artwork brackets")
	_send_key(viewport, KEY_RIGHT)
	_check(boss.has_focus() and _focus_brackets(boss).visible, "Right returns the visible focus to the boss")
	_move_to(viewport, _art(first).get_global_rect().get_center())
	_check(boss.has_focus() and not _focus_brackets(boss).visible and _art(first).self_modulate != Color.WHITE,
		"switching back to mouse hides the keyboard cue without discarding focus")
	var art := _art(boss)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = art.get_global_rect().get_center()
		event.pressed = pressed
		viewport.push_input(event, true)
	_check(_clicked == "2", "a press on the boss image reaches the selection button")
	_check((boss.get_node("PortalVoters") as Label).text.is_empty(), "click alone does not render a submitted vote")
	boss.disabled = true
	PortalChoiceButton.show_votes(boss, {"Battle Mage 1": "2", "Battle Mage 2": "0"})
	var voters := boss.get_node("PortalVoters") as Label
	_move_to(viewport, _art(first).get_global_rect().get_center())
	_check(voters.text == "Battle Mage 1" and boss.get_theme_color("font_disabled_color") == PortalChoiceButton.GOLD
		and not _focus_brackets(boss).visible and art.self_modulate == Color.WHITE,
		"only the submitted choice retains its gold vote caption while input is locked")
	PortalChoiceButton.show_votes(boss, {})
	_check(voters.text.is_empty() and boss.get_theme_color("font_disabled_color") != PortalChoiceButton.GOLD,
		"clearing the vote projection restores the ordinary caption")
	viewport.queue_free()
	await process_frame


func _art(button: Button) -> TextureRect:
	return button.get_node("PortalArt") as TextureRect


func _focus_brackets(button: Button) -> Control:
	return _art(button).get_node("PortalKeyboardFocus") as Control


func _move_to(viewport: SubViewport, position: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	viewport.push_input(motion, true)


func _send_key(viewport: SubViewport, key: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = key
		event.pressed = pressed
		viewport.push_input(event, true)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
