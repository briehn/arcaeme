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
	_check(boss.get_theme_stylebox("focus").border_width_left > 0, "the focus outline surrounds the image button")
	var art := boss.get_node("PortalArt") as TextureRect
	_clicked = ""
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = art.get_global_rect().get_center()
		event.pressed = pressed
		viewport.push_input(event, true)
	_check(_clicked == "2", "a press on the boss image reaches the selection button")
	PortalChoiceButton.show_votes(boss, {"Battle Mage 1": "2", "Battle Mage 2": "0"})
	var voters := boss.get_node("PortalVoters") as Label
	_check(voters.text == "Battle Mage 1", "the choice displays the Mages who picked it")
	viewport.queue_free()
	await process_frame


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
