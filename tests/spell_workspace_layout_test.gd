extends SceneTree

const Pool = preload("res://scripts/run/battle_mage_pool_playtest.gd")
const Matcher = preload("res://scripts/combat/rune_matcher.gd")
const RuneCanvas = preload("res://scripts/ui/rune_canvas.gd")
const DrawingPanel = preload("res://scripts/ui/spell_drawing_panel.gd")
const PANEL = preload("res://scenes/spell_drawing_panel.tscn")
const COMBAT = preload("res://scenes/combat.tscn")
const TWO_SLIMES = preload("res://resources/prototype/enemies/two_slimes.tres")
const SETTINGS = preload("res://resources/prototype/spell_drawing_settings.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const SALVO = preload("res://resources/prototype/cards/expansion/astral_salvo.tres")
const VIEWPORT_SIZES := [Vector2i(960, 540), Vector2i(1024, 576), Vector2i(1280, 720), Vector2i(1920, 1080)]

var _viewport: SubViewport
var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var normalized_references := {}
	var native := DisplayServer.get_name() != "headless"
	for resolution in VIEWPORT_SIZES:
		_viewport = SubViewport.new()
		_viewport.size = resolution
		if native:
			_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(_viewport)
		var combat = COMBAT.instantiate()
		combat.encounter = TWO_SLIMES
		_viewport.add_child(combat)
		var panel := PANEL.instantiate() as DrawingPanel
		_viewport.add_child(panel)
		var canvas := panel.get_node("%RuneCanvas") as RuneCanvas
		panel.cast_surface_ready.connect(func(): panel.start_timer(Time.get_ticks_msec() + 60_000))
		var boosted := SALVO.rune_template.strokes.duplicate()
		boosted.append(SALVO.rune_template.booster_stroke)
		panel.open_cast(SALVO.display_name, "Salvo Rune · extra stroke", boosted,
			"2 Mana · 36/36 HP\nSlime (2) · 22/22 HP")
		for frame in 5:
			await process_frame
		_test_layout(panel, canvas)
		_test_all_guides(canvas, normalized_references)
		canvas.set_guide(boosted)
		_print_measurements(panel, canvas, boosted)
		await _test_brush(canvas, native)
		panel.close_cast()
		_check(not canvas._brush_overlay.visible and canvas.completed_strokes(true).is_empty(),
			"closing the panel clears captured ink and the brush")
		_viewport.queue_free()
		await process_frame
	print("Spell workspace layout: %d checks at %d viewport sizes, %d failures." % [
		_checks, VIEWPORT_SIZES.size(), _failures])
	quit(int(_failures > 0))


func _test_layout(panel: DrawingPanel, canvas: RuneCanvas) -> void:
	var screen := Rect2(Vector2.ZERO, Vector2(_viewport.size))
	var surface := canvas._surface()
	var old_canvas_side := minf(380.0, _viewport.size.y - 205.0)
	_check(panel._surface_ready and canvas._drawing_enabled, "the visible layout accepts input")
	_check(surface.size.x > old_canvas_side - 32.0 and is_equal_approx(surface.size.aspect(), 1.0),
		"the square drawing surface is larger than the previous layout")
	_check(screen.encloses(canvas.get_global_rect()), "the full canvas stays onscreen")
	for path in ["%CardTitle", "%RuneName", "%CastContext", "%TimeLabel", "%Instructions",
			"%CancelButton", "%ClearButton", "%SubmitButton"]:
		var control := panel.get_node(path) as Control
		var rect := control.get_global_rect()
		_check(control.is_visible_in_tree() and rect.has_area() and screen.encloses(rect) and
			not rect.intersects(canvas.get_global_rect()), "%s is readable and clear of the canvas" % path)
	_check("extra stroke" in (panel.get_node("%RuneName") as Label).text, "the header identifies the active augmentation")
	var clear := panel.get_node("%ClearButton") as Button
	var cancel := panel.get_node("%CancelButton") as Button
	var submit := panel.get_node("%SubmitButton") as Button
	_check(not cancel.get_global_rect().intersects(clear.get_global_rect())
		and not submit.get_global_rect().intersects(clear.get_global_rect()),
		"the footer controls do not overlap")


func _test_all_guides(canvas: RuneCanvas, normalized_references: Dictionary) -> void:
	for card in Pool.catalogue():
		for boosted in [false, true]:
			var label := "%s%s" % [card.display_name, " boosted" if boosted else ""]
			var guide := card.rune_template.strokes.duplicate()
			if boosted:
				guide.append(card.rune_template.booster_stroke)
			canvas.set_guide(guide)
			var surface := canvas._surface()
			var projected := _guide_bounds(canvas, guide)
			var original := _bounds(guide)
			var fraction := projected.size / surface.size
			_check(surface.encloses(projected) and projected.get_center().is_equal_approx(surface.get_center())
				and fraction.x <= 0.861 and fraction.y <= 0.761
				and (is_equal_approx(fraction.x, 0.86) or is_equal_approx(fraction.y, 0.76)),
				"%s fits within the limiting axis and stays centered" % label)
			_check(is_equal_approx(projected.size.x / original.size.x, projected.size.y / original.size.y),
				"%s uses uniform scale" % label)
			var paths: Array[PackedVector2Array] = []
			var ink_aligned := true
			for stroke in guide:
				var display := canvas._local_points(stroke)
				var path := PackedVector2Array()
				for point in display:
					path.append(canvas._normalize(point))
				var ink := canvas._ink_points(path)
				ink_aligned = ink_aligned and _paths_approx(ink, display)
				paths.append(path)
			_check(ink_aligned, "%s captured path renders back on its displayed guide" % label)
			if normalized_references.has(label):
				var prior: Array = normalized_references[label]
				var same := true
				for index in paths.size():
					same = same and _paths_approx(paths[index], prior[index])
				_check(same, "%s normalizes to the same paths across sizes" % label)
			else:
				normalized_references[label] = paths
			var match_result := Matcher.recognize(guide, paths, SETTINGS.minimum_extent,
				SETTINGS.recognition_tolerance, SETTINGS.minimum_coverage)
			_check(match_result != null and match_result.complete and match_result.score > 0.999,
				"%s fitted geometry still matches its template without score loss" % label)


func _test_brush(canvas: RuneCanvas, native: bool) -> void:
	var surface := canvas._surface()
	var transform := canvas.get_global_transform_with_canvas()
	var sample := surface.position + surface.size * Vector2(0.20, 0.15)
	var below := surface.position + surface.size * Vector2(0.25, 0.85)
	var ink_tip := surface.position + surface.size * Vector2(0.53, 0.85)
	var cursor := canvas.mouse_default_cursor_shape
	_pointer(Vector2(2, 2))
	var clean: Image
	if native:
		clean = await _frame()
	_pointer(transform * sample)
	var brush := canvas._brush_overlay
	_check(brush.is_visible_in_tree() and brush.position.is_equal_approx(sample)
		and brush.get_parent() == canvas and not brush.show_behind_parent and canvas.mouse_default_cursor_shape == cursor,
		"pointer hover is centered above the guide and keeps the normal cursor")
	_check(canvas.completed_strokes(true).is_empty(), "hover alone adds no ink")
	var radius := canvas._ink_width() * 0.5
	if native:
		var hover := await _frame()
		var hover_center := transform * sample
		var edge_delta := _rim_delta(clean, hover, hover_center, radius)
		var center_delta := _pixel_delta(clean, hover, Vector2i(hover_center))
		_check(edge_delta >= 0.45 and edge_delta > center_delta * 1.5,
			"rendered hover rim has strong contrast and a restrained center (rim %.2f, fill %.2f)" %
				[edge_delta, center_delta])
	_button(transform * below, true)
	_pointer(transform * ink_tip, MOUSE_BUTTON_MASK_LEFT)
	_check(brush.visible and brush.position.is_equal_approx(ink_tip)
		and canvas._current.size() == 2, "brush stays at the active ink tip")
	_button(transform * ink_tip, false)
	if native:
		_pointer(transform * ink_tip)
		var active := await _frame()
		if "--capture" in OS.get_cmdline_user_args() and _viewport.size.x in [960, 1280]:
			var path := OS.get_environment("TEMP").path_join("arcaeme-m20b-workspace-%dx%d.png" % [
				_viewport.size.x, _viewport.size.y])
			_check(active.save_png(path) == OK, "native workspace capture saved")
			print("WORKSPACE_CAPTURE ", path)
		brush.hide()
		var ink := await _frame()
		var edge_delta := _rim_delta(ink, active, transform * ink_tip, radius)
		_check(edge_delta > 0.35, "the rendered rim remains distinct above drawn ink (%.2f)" % edge_delta)
	_pointer(Vector2(2, 2))
	_check(not brush.visible and canvas.completed_strokes().size() == 1,
		"leaving hides the footprint and preserves the recorded stroke")


func _frame() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return _viewport.get_texture().get_image()


func _pixel_delta(before: Image, after: Image, pixel: Vector2i) -> float:
	var a := before.get_pixelv(pixel)
	var b := after.get_pixelv(pixel)
	return maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b)))


func _rim_delta(before: Image, after: Image, center: Vector2, radius: float) -> float:
	var greatest := 0.0
	var reach := ceili(radius + 1.0)
	for y in range(-reach, reach + 1):
		for x in range(-reach, reach + 1):
			var distance := Vector2(x, y).length()
			if distance >= radius * 0.50 and distance <= radius + 0.75:
				greatest = maxf(greatest, _pixel_delta(before, after, Vector2i(center) + Vector2i(x, y)))
	return greatest


func _pointer(position: Vector2, mask := 0) -> void:
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	event.button_mask = mask
	_viewport.push_input(event, true)


func _button(position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	_viewport.push_input(event, true)


func _paths_approx(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	if a.size() != b.size():
		return false
	for index in a.size():
		if not a[index].is_equal_approx(b[index]):
			return false
	return true


func _guide_bounds(canvas: RuneCanvas, strokes: Array[PackedVector2Array]) -> Rect2:
	var projected: Array[PackedVector2Array] = []
	for stroke in strokes:
		projected.append(canvas._local_points(stroke))
	return _bounds(projected)


func _bounds(strokes: Array[PackedVector2Array]) -> Rect2:
	var result := Rect2(strokes[0][0], Vector2.ZERO)
	for stroke in strokes:
		for point in stroke:
			result = result.expand(point)
	return result


func _print_measurements(panel: DrawingPanel, canvas: RuneCanvas, boosted: Array[PackedVector2Array]) -> void:
	var workspace := panel.get_node("Workspace") as Control
	var salvo := _guide_bounds(canvas, boosted).size
	canvas.set_guide(STRIKE.rune_template.strokes)
	var strike := _guide_bounds(canvas, STRIKE.rune_template.strokes).size
	canvas.set_guide(boosted)
	print("WORKSPACE ", JSON.stringify({
		"viewport": str(_viewport.size), "workspace": str(workspace.size), "canvas": str(canvas.size),
		"surface": str(canvas._surface().size), "basic_strike": str(strike), "boosted_salvo": str(salvo),
		"ink": canvas._ink_width(),
	}))


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("%s — %s" % [_viewport.size, message])
