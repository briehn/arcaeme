extends SceneTree

const CombatView = preload("res://scripts/combat.gd")
const CardData = preload("res://scripts/combat/card_data.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const RuneTemplate = preload("res://scripts/combat/rune_template.gd")
const RuneCanvas = preload("res://scripts/ui/rune_canvas.gd")
const MENU = preload("res://scenes/main.tscn")
const SOLO = preload("res://scenes/combat.tscn")
const LOCAL = preload("res://scenes/local_coop.tscn")
const TWO_SLIMES = preload("res://resources/prototype/enemies/two_slimes.tres")
const DRAWING_SETTINGS = preload("res://resources/prototype/spell_drawing_settings.tres")
const ASTRA = preload("res://resources/prototype/cards/expansion/astral_salvo.tres")
const BLOCK = preload("res://resources/prototype/cards/basic_block.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const FIRST_TARGET := &"slime_1"
const SECOND_TARGET := &"slime_2"
const SHORT_CAST_MS := 800
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
		await _test_expiry()
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
	var surface_signal := {"count": 0, "remaining_ms": 0}
	panel.connect(&"cast_surface_ready", func():
		surface_signal.count += 1
		surface_signal.remaining_ms = int(panel.get("_deadline_ms")) - Time.get_ticks_msec()
	)

	await _click(_card(combat, "Basic Strike"))
	_check(not panel.visible and combat.get_node("%TargetLabel").visible,
		"attack selects an enemy before opening the rune overlay")
	await _click(combat._enemy_buttons[SECOND_TARGET], false)
	_check(panel.visible and surface_signal.count == 0 and int(panel.get("_deadline_ms")) == 0
		and not canvas._drawing_enabled, "the preparation frame keeps both the clock and input idle")
	await _settle()
	_check(surface_signal.count == 1 and canvas._drawing_enabled
		and surface_signal.remaining_ms > STRIKE.rune_template.cast_time_ms - 500
		and surface_signal.remaining_ms <= STRIKE.rune_template.cast_time_ms,
		"the usable surface starts the full timer once")
	_check(panel.visible and guide_label.text == "Strike Rune" and cast_button.disabled and end_turn.disabled,
		"target opens the rune overlay with timer, blank cast disabled, and End Turn locked")
	_check("any order or direction" in (panel.find_child("Instructions", true, false) as Label).text,
		"the guide describes free stroke order and direction")
	var cast_context := panel.get_node("%CastContext") as Label
	_check(_fully_visible(cast_context) and "3 Mana" in cast_context.text
		and "Slime (2)" in cast_context.text and "22/22 HP" in cast_context.text,
		"the casting header keeps the selected target and available Mana visible")
	_check(player.mana == 3 and player.hand.size() == 5 and state.action_history.is_empty(),
		"showing the target-specific cast spends no Mana and removes no card")
	_check(_fully_visible(canvas) and absf(canvas._surface().size.aspect() - 1.0) < 0.01
		and _fully_visible(panel.get_node("%TimeLabel")) and _fully_visible(cast_button),
		"the square canvas, timer, and Cast control fit")
	await _test_brush(canvas, panel, cast_button)

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

	await _click(_card(combat, "Basic Strike"))
	await _click(combat._enemy_buttons[SECOND_TARGET])
	_draw_stroke(canvas, PackedVector2Array([
		Vector2(0.15, 0.72), Vector2(0.83, 0.22), Vector2(0.24, 0.22),
		Vector2(0.83, 0.82), Vector2(0.13, 0.40),
	]), true, false)
	await _click(cast_button)
	_check(not panel.visible and "unrecognized" in combat.spell_feedback.text.to_lower(),
		"an unrelated mouse drawing reports failed recognition")
	_check(player.mana == 3 and player.hand.size() == 5 and state.action_history.is_empty(),
		"an unrecognized cast keeps its card and Mana and records no action")

	await _click(_card(combat, "Spell Ink Booster"))
	_check(not panel.visible and player.mana == 2 and player.hand.size() == 4
		and "extra stroke" in combat.spell_feedback.text, "Booster resolves instantly and primes an extra stroke")
	await _select_salvo(combat)
	_check(panel.visible and "extra stroke" in guide_label.text and canvas._guide.size() == 3
		and canvas._guide[-1] == ASTRA.rune_template.booster_stroke
		and _connects_to_rune(canvas._guide), "the boosted Salvo visibly includes its connected third stroke")
	for index in [2, 0, 1]:
		var stroke := canvas._guide[index].duplicate()
		if index != 1:
			stroke.reverse()
		_draw_stroke(canvas, stroke)
	await _click(cast_button)
	_check(not panel.visible and "excellent" in combat.spell_feedback.text.to_lower()
		and "130% base power" in combat.spell_feedback.text, "shuffled and reversed mouse traces give an excellent boosted Salvo")
	_check(state.enemy_state(FIRST_TARGET).hp == 18 and state.enemy_state(SECOND_TARGET).hp == 4,
		"both 9-damage hits resolve against only the selected enemy")
	_check(player.mana == 0 and player.hand.size() == 3 and player.discard_pile.size() == 2
		and not player.spell_booster_primed and state.action_history.size() == 2,
		"successful cast spends Mana, moves its card, and consumes the booster once")
	combat.queue_free()
	await _settle()


func _test_expiry() -> void:
	var combat := await _open_combat(SOLO, false, SHORT_CAST_MS)
	var state := combat._state
	var player = state.players[CombatView.PLAYER_ID]
	var panel := combat.get_node("SpellDrawingPanel") as Control
	var canvas := panel.get_node("%RuneCanvas") as RuneCanvas
	await _click(_card(combat, "Spell Ink Booster"))
	await _select_salvo(combat)
	_check(panel.visible and canvas._guide.size() == 3 and player.mana == 2,
		"the short expiry fixture starts a primed cast with its card and Mana reserved")
	var outline: PackedVector2Array = ASTRA.rune_template.strokes[0]
	outline = outline.duplicate()
	outline.reverse()
	_draw_stroke(canvas, outline, false)
	var release_position := canvas.get_global_transform_with_canvas() * canvas._local_points(outline)[-1]
	_check((panel.get_node("%SubmitButton") as Button).disabled,
		"the captured outline is still held rather than submitted manually")
	var deadline := Time.get_ticks_msec() + SHORT_CAST_MS + 2500
	while panel.visible and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(not panel.visible and "time up" in combat.spell_feedback.text.to_lower()
		and "75% base power" in combat.spell_feedback.text,
		"expiry recognizes the held outline as a partial spell with reduced power")
	_check(state.enemy_state(FIRST_TARGET).hp == 18 and state.enemy_state(SECOND_TARGET).hp == 12
		and player.mana == 0 and player.hand.size() == 3 and player.discard_pile.size() == 2
		and not player.spell_booster_primed and state.action_history.size() == 2,
		"partial expiry resolves both hits, spends once, and consumes the undrawn booster")
	_mouse_button(release_position, false)
	await _settle()
	_check(not panel.visible and state.enemy_state(SECOND_TARGET).hp == 12 and state.action_history.size() == 2,
		"releasing after automatic resolution cannot reopen or resolve the spell again")
	combat.queue_free()
	await _settle()


func _test_brush(canvas: RuneCanvas, panel: Control, cast_button: Button) -> void:
	var surface := canvas._surface()
	var origin := canvas.get_global_transform_with_canvas()
	var overlay := canvas._brush_overlay
	var cursor := canvas.mouse_default_cursor_shape
	var start := surface.position + surface.size * 0.35
	var tip := surface.position + surface.size * 0.65
	var baseline_width := canvas.reference_ink_width
	var expected_width := baseline_width * surface.size.x / 348.0
	_check(baseline_width > 9.0 and is_equal_approx(canvas._ink_width(), expected_width),
		"visible ink uses the larger reference diameter and scales with the surface")
	canvas.reference_ink_width = baseline_width + 2.0
	_check(is_equal_approx(canvas._ink_width(), expected_width * (baseline_width + 2.0) / baseline_width),
		"brush diameter is configurable")
	canvas.reference_ink_width = baseline_width
	_mouse_motion(origin * start)
	_check(overlay.is_visible_in_tree() and overlay.position.is_equal_approx(start)
		and overlay.get_parent() == canvas and not overlay.show_behind_parent and canvas.mouse_default_cursor_shape == cursor,
		"hover centers a separate overlay above the guide while keeping the existing cursor")
	_check(canvas.completed_strokes(true).is_empty() and canvas._current.is_empty() and cast_button.disabled,
		"hover previews the brush without depositing or preparing ink")
	_mouse_motion(origin * Vector2(5.0, 5.0))
	_check(not overlay.visible and canvas.mouse_default_cursor_shape == cursor,
		"canvas padding hides the footprint and keeps the normal cursor")
	_mouse_motion(origin * start)
	_check(overlay.visible and canvas._current.is_empty(), "reentry restores the preview without drawing")
	_mouse_button(origin * start, true)
	_mouse_motion(origin * tip, MOUSE_BUTTON_MASK_LEFT)
	_check(overlay.visible and overlay.position.is_equal_approx(tip) and canvas.mouse_default_cursor_shape == cursor
		and canvas._current.size() == 2 and cast_button.disabled,
		"the brush follows the held pointer while only pressed motion deposits ink")
	_mouse_button(origin * tip, false)
	var recorded := canvas.completed_strokes()
	_mouse_motion(Vector2(2.0, 2.0))
	_check(not overlay.visible and canvas.completed_strokes() == recorded and not cast_button.disabled,
		"leaving the canvas hides the preview and retains only the finished ink")
	await _click(panel.get_node("%ClearButton"))
	_check(canvas.completed_strokes(true).is_empty() and cast_button.disabled, "Clear still erases the captured ink")


func _mouse_motion(position: Vector2, mask := 0) -> void:
	var event := InputEventMouseMotion.new()
	event.button_mask = mask
	event.position = position
	event.global_position = position
	_viewport.push_input(event, true)


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
	_check(player_two.block == 6 and player_two.mana == 2 and player_one.block == 0
		and player_one.spell_booster_primed, "excellent Block and the booster stay with their respective Mages")
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


func _open_combat(scene: PackedScene, bypass := false, salvo_duration_ms := 0) -> CombatView:
	var combat := scene.instantiate() as CombatView
	var fixture: EncounterData = TWO_SLIMES.duplicate()
	fixture.test_deck = DRAWING_SETTINGS.test_deck.duplicate()
	if salvo_duration_ms > 0:
		var salvo: CardData = ASTRA.duplicate()
		var rune: RuneTemplate = ASTRA.rune_template.duplicate()
		rune.cast_time_ms = salvo_duration_ms
		salvo.rune_template = rune
		fixture.test_deck[fixture.test_deck.find(ASTRA)] = salvo
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


func _connects_to_rune(guide: Array[PackedVector2Array]) -> bool:
	var extra := guide[-1]
	for path_index in range(guide.size() - 1):
		var base := guide[path_index]
		for index in range(1, base.size()):
			for extra_index in range(1, extra.size()):
				if Geometry2D.segment_intersects_segment(base[index - 1], base[index],
						extra[extra_index - 1], extra[extra_index]) != null:
					return true
				for tip in [extra[extra_index - 1], extra[extra_index]]:
					if tip.distance_to(Geometry2D.get_closest_point_to_segment(tip, base[index - 1], base[index])) < 0.001:
						return true
	return false


func _draw_stroke(canvas: RuneCanvas, stroke: PackedVector2Array, release := true, template_space := true) -> void:
	var points := canvas._local_points(stroke) if template_space else canvas._ink_points(stroke)
	var transform := canvas.get_global_transform_with_canvas()
	_mouse_button(transform * points[0], true)
	for index in range(1, points.size()):
		var event := InputEventMouseMotion.new()
		event.button_mask = MOUSE_BUTTON_MASK_LEFT
		event.position = transform * points[index]
		event.global_position = event.position
		_viewport.push_input(event, true)
	if release:
		_mouse_button(transform * points[-1], false)


func _mouse_button(position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = position
	event.global_position = position
	event.pressed = pressed
	_viewport.push_input(event, true)


func _click(control: Control, settle := true) -> void:
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
	if settle:
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
