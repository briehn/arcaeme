extends Control

signal strokes_changed

const GUIDE_COLOR := Color(0.54, 0.81, 0.9, 0.85)
const GUIDE_TEXT := Color(0.94, 0.97, 1.0)
const INK_COLOR := Color(1.0, 0.84, 0.54)
const SURFACE_COLOR := Color(0.08, 0.11, 0.17)
const FRAME_COLOR := Color(0.31, 0.42, 0.55)
const MIN_POINT_DISTANCE_SQUARED := 0.000004

var _guide: Array[PackedVector2Array] = []
var _strokes: Array[PackedVector2Array] = []
var _current := PackedVector2Array()


func set_guide(guide: Array[PackedVector2Array]) -> void:
	_guide = guide.duplicate()
	clear_strokes()


func clear_strokes() -> void:
	_strokes.clear()
	_current.clear()
	_strokes_changed()


func has_completed_strokes() -> bool:
	return not _strokes.is_empty() and _current.is_empty()


func completed_strokes() -> Array[PackedVector2Array]:
	return _strokes.duplicate()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		if event.pressed:
			if _surface().has_point(event.position):
				_current = PackedVector2Array([_normalize(event.position)])
				_strokes_changed()
		elif not _current.is_empty():
			_append_point(event.position)
			if _current.size() > 1:
				_strokes.append(_current)
			_current = PackedVector2Array()
			_strokes_changed()
	elif event is InputEventMouseMotion and not _current.is_empty():
		accept_event()
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_append_point(event.position)
		else:
			_discard_current()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT and not _current.is_empty():
		_discard_current()


func _append_point(position_on_canvas: Vector2) -> void:
	var point := _normalize(position_on_canvas)
	if _current[-1].distance_squared_to(point) >= MIN_POINT_DISTANCE_SQUARED:
		_current.append(point)
		queue_redraw()


func _discard_current() -> void:
	_current.clear()
	_strokes_changed()


func _strokes_changed() -> void:
	queue_redraw()
	strokes_changed.emit()


func _surface() -> Rect2:
	return Rect2(Vector2.ZERO, size).grow(-16.0)


func _normalize(position_on_canvas: Vector2) -> Vector2:
	var surface := _surface()
	return ((position_on_canvas - surface.position) / surface.size).clamp(Vector2.ZERO, Vector2.ONE)


func _local_points(stroke: PackedVector2Array) -> PackedVector2Array:
	var surface := _surface()
	var points := PackedVector2Array()
	for point in stroke:
		points.append(surface.position + point * surface.size)
	return points


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), SURFACE_COLOR)
	draw_rect(Rect2(Vector2.ONE, size - Vector2(2.0, 2.0)), FRAME_COLOR, false, 1.0)
	var font := get_theme_default_font()
	for index in _guide.size():
		var stroke := _local_points(_guide[index])
		if stroke.size() < 2:
			continue
		for point in range(1, stroke.size()):
			draw_dashed_line(stroke[point - 1], stroke[point], GUIDE_COLOR, 3.0, 8.0, true, true)
		var tip := stroke[-1]
		var direction := (tip - stroke[-2]).normalized()
		var wing := direction.orthogonal() * 5.0
		draw_colored_polygon(PackedVector2Array([tip, tip - direction * 13.0 + wing,
			tip - direction * 13.0 - wing]), GUIDE_COLOR)
		draw_circle(stroke[0], 10.0, SURFACE_COLOR)
		draw_arc(stroke[0], 10.0, 0.0, TAU, 20, GUIDE_COLOR, 1.4, true)
		var number := str(index + 1)
		var number_width := font.get_string_size(number, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		draw_string(font, stroke[0] + Vector2(-number_width * 0.5, 5.0), number,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, GUIDE_TEXT)
	for stroke in _strokes:
		_draw_ink(stroke)
	_draw_ink(_current)


func _draw_ink(stroke: PackedVector2Array) -> void:
	if stroke.is_empty():
		return
	var points := _local_points(stroke)
	if points.size() > 1:
		draw_polyline(points, INK_COLOR, 3.0, true)
	draw_circle(points[-1], 2.5, INK_COLOR)
