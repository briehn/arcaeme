extends Control

signal strokes_changed

const GUIDE_COLOR := Color(0.54, 0.81, 0.9, 0.85)
const INK_COLOR := Color(1.0, 0.84, 0.54)
const REFERENCE_SURFACE_SIDE := 348.0
const BRUSH_OUTLINE := Color(0.86, 0.98, 1.0, 0.98)
const BRUSH_EDGE := Color(0.06, 0.12, 0.18, 0.97)
const BRUSH_FILL := Color(0.60, 0.89, 1.0, 0.20)
const SURFACE_COLOR := Color(0.08, 0.11, 0.17)
const FRAME_COLOR := Color(0.31, 0.42, 0.55)
const MIN_POINT_DISTANCE_SQUARED := 0.000004

## Ink diameter on the reference canvas (380 px square with 16 px padding).
@export_range(1.0, 40.0, 0.5) var reference_ink_width := 9.0

var _guide: Array[PackedVector2Array] = []
var _strokes: Array[PackedVector2Array] = []
var _current := PackedVector2Array()
var _drawing_enabled := false
var _brush_overlay: Node2D


func _ready() -> void:
	_brush_overlay = Node2D.new()
	_brush_overlay.hide()
	add_child(_brush_overlay)
	_brush_overlay.draw.connect(_draw_brush)


func set_guide(guide: Array[PackedVector2Array]) -> void:
	_guide = guide.duplicate()
	clear_strokes()


func clear_strokes() -> void:
	_strokes.clear()
	_current.clear()
	_strokes_changed()


func has_completed_strokes() -> bool:
	return not _strokes.is_empty() and _current.is_empty()


func set_drawing_enabled(enabled: bool) -> void:
	_drawing_enabled = enabled
	_update_brush(get_local_mouse_position())


func completed_strokes(include_in_progress := false) -> Array[PackedVector2Array]:
	var strokes := _strokes.duplicate()
	if include_in_progress and _current.size() > 1:
		strokes.append(_current.duplicate())
	return strokes


func _input(event: InputEvent) -> void:
	# Observe pointer motion even when the GUI routes it to another control or a drag owns it.
	if _drawing_enabled and is_visible_in_tree() and event is InputEventMouseMotion:
		_update_brush(get_global_transform_with_canvas().affine_inverse() * event.position)


func _gui_input(event: InputEvent) -> void:
	if not _drawing_enabled:
		return
	if event is InputEventMouseButton:
		_update_brush(event.position)
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
		if _drawing_enabled:
			_update_brush(get_local_mouse_position())
	elif what == NOTIFICATION_MOUSE_ENTER:
		_update_brush(get_local_mouse_position())
	elif what == NOTIFICATION_MOUSE_EXIT or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_hide_brush()
		if what == NOTIFICATION_APPLICATION_FOCUS_OUT and not _current.is_empty():
			_discard_current()


func _update_brush(local_position: Vector2) -> void:
	if not _drawing_enabled or not _surface().has_point(local_position):
		_hide_brush()
		return
	_brush_overlay.position = local_position
	_brush_overlay.show()
	_brush_overlay.queue_redraw()


func _hide_brush() -> void:
	if _brush_overlay != null:
		_brush_overlay.hide()


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


func _ink_width() -> float:
	var surface_size := _surface().size
	return reference_ink_width * minf(surface_size.x, surface_size.y) / REFERENCE_SURFACE_SIDE


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
	for guide_stroke in _guide:
		var stroke := _local_points(guide_stroke)
		for point in range(1, stroke.size()):
			draw_dashed_line(stroke[point - 1], stroke[point], GUIDE_COLOR, 3.0, 8.0, true, true)
	for stroke in _strokes:
		_draw_ink(stroke)
	_draw_ink(_current)


func _draw_brush() -> void:
	# The mouse-transparent child renders over both the guide and player ink.
	var radius := _ink_width() * 0.5
	var rim := minf(1.2, radius * 0.30)
	_brush_overlay.draw_circle(Vector2.ZERO, radius, BRUSH_FILL, true, -1.0, true)
	_brush_overlay.draw_arc(Vector2.ZERO, radius - rim, 0.0, TAU, 32, BRUSH_EDGE, rim * 2.0, true)
	_brush_overlay.draw_arc(Vector2.ZERO, radius - rim * 1.5, 0.0, TAU, 32, BRUSH_OUTLINE, rim, true)


func _draw_ink(stroke: PackedVector2Array) -> void:
	if stroke.is_empty():
		return
	var points := _local_points(stroke)
	var width := _ink_width()
	for index in range(1, points.size()):
		draw_line(points[index - 1], points[index], INK_COLOR, width, true)
	for point in points:
		draw_circle(point, width * 0.5, INK_COLOR, true, -1.0, true)
