extends Control

signal strokes_changed

enum DrawingMode { HOLD, TOGGLE }

const GUIDE_COLOR := Color("#b5a3db")
const INK_COLOR := Color(1.0, 0.84, 0.54)
const REFERENCE_SURFACE_SIDE := 348.0
const BRUSH_OUTLINE := Color("#fff4dc")
const BRUSH_EDGE := Color("#1d0c2b")
const BRUSH_FILL := Color(1.0, 0.86, 0.63, 0.24)
const GUIDE_HEIGHT_FRACTION := 0.76
const GUIDE_WIDTH_FRACTION := 0.86
const MIN_POINT_DISTANCE_SQUARED := 0.000004

## Ink diameter on the reference canvas (380 px square with 16 px padding).
@export_range(1.0, 40.0, 0.5) var reference_ink_width := 11.0

static var session_input_mode: DrawingMode = DrawingMode.HOLD

var _guide: Array[PackedVector2Array] = []
var _guide_fit := Transform2D.IDENTITY
var _strokes: Array[PackedVector2Array] = []
var _current := PackedVector2Array()
var _drawing_enabled := false
var _drawing_deadline_ms := 0
var _input_mode: DrawingMode = DrawingMode.HOLD
var _brush_overlay: Node2D


func _ready() -> void:
	_brush_overlay = Node2D.new()
	_brush_overlay.hide()
	add_child(_brush_overlay)
	_brush_overlay.draw.connect(_draw_brush)


func set_guide(guide: Array[PackedVector2Array]) -> void:
	_guide = guide.duplicate()
	_guide_fit = _fit_guide(guide)
	clear_strokes()


func clear_strokes() -> void:
	_strokes.clear()
	_current.clear()
	_strokes_changed()


func has_completed_strokes() -> bool:
	return not _strokes.is_empty() and _current.is_empty()


func set_drawing_enabled(enabled: bool, deadline_ms := 0) -> void:
	_drawing_enabled = enabled
	_drawing_deadline_ms = deadline_ms if enabled else 0
	_update_brush(get_local_mouse_position())


func set_input_mode(mode: DrawingMode) -> void:
	if mode != _input_mode:
		_finish_stroke()
		_input_mode = mode


func toggle_stroke() -> void:
	if not _drawing_enabled or not is_visible_in_tree() or _input_mode != DrawingMode.TOGGLE:
		return
	var position_on_canvas := get_local_mouse_position()
	if not _current.is_empty():
		if _surface().has_point(position_on_canvas):
			_append_point(position_on_canvas)
		_finish_stroke()
		return
	if _surface().has_point(position_on_canvas):
		_begin_stroke(position_on_canvas)


func completed_strokes(include_in_progress := false) -> Array[PackedVector2Array]:
	var strokes := _strokes.duplicate()
	if include_in_progress and _current.size() > 1:
		strokes.append(_current.duplicate())
	return strokes


func _input(event: InputEvent) -> void:
	# Observe pointer motion even when the GUI routes it to another control or a drag owns it.
	if _drawing_enabled and is_visible_in_tree() and event is InputEventMouseMotion:
		var position_on_canvas: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
		_update_brush(position_on_canvas)
		if not _surface().has_point(position_on_canvas):
			_finish_stroke()
		elif (_input_mode == DrawingMode.TOGGLE and not _current.is_empty()
				and (_drawing_deadline_ms == 0 or Time.get_ticks_msec() < _drawing_deadline_ms)):
			# Unheld viewport motion may not reach GUI input in a SubViewport.
			if event.button_mask == 0:
				_append_point(position_on_canvas)
			else:
				_finish_stroke()


func _gui_input(event: InputEvent) -> void:
	if not _drawing_enabled:
		return
	if event is InputEventMouseButton:
		_update_brush(event.position)
	if _input_mode != DrawingMode.HOLD:
		if event is InputEventMouseButton and event.pressed:
			_finish_stroke()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		if event.pressed:
			if _surface().has_point(event.position):
				_begin_stroke(event.position)
		elif not _current.is_empty():
			if _surface().has_point(event.position):
				_append_point(event.position)
			_finish_stroke()
	elif event is InputEventMouseMotion and not _current.is_empty():
		accept_event()
		if _surface().has_point(event.position) and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_append_point(event.position)
		else:
			_finish_stroke()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()
		if _drawing_enabled:
			_update_brush(get_local_mouse_position())
	elif what == NOTIFICATION_MOUSE_ENTER:
		_update_brush(get_local_mouse_position())
	elif what == NOTIFICATION_MOUSE_EXIT:
		_hide_brush()
		_finish_stroke()
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_hide_brush()
		if not _current.is_empty():
			_current.clear()
			_strokes_changed()


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


func _begin_stroke(position_on_canvas: Vector2) -> void:
	_current = PackedVector2Array([_normalize(position_on_canvas)])
	_strokes_changed()


func _finish_stroke() -> void:
	if _current.is_empty():
		return
	if _current.size() > 1:
		_strokes.append(_current)
	_current = PackedVector2Array()
	_strokes_changed()


func _strokes_changed() -> void:
	queue_redraw()
	strokes_changed.emit()


func _surface() -> Rect2:
	var side := maxf(0.0, minf(size.x, size.y) - 32.0)
	var square := Vector2.ONE * side
	return Rect2((size - square) * 0.5, square)


func _ink_width() -> float:
	var surface_size := _surface().size
	return reference_ink_width * minf(surface_size.x, surface_size.y) / REFERENCE_SURFACE_SIDE


func _normalize(position_on_canvas: Vector2) -> Vector2:
	var surface := _surface()
	return ((position_on_canvas - surface.position) / surface.size).clamp(Vector2.ZERO, Vector2.ONE)


func _fit_guide(guide: Array[PackedVector2Array]) -> Transform2D:
	if guide.is_empty() or guide[0].is_empty():
		return Transform2D.IDENTITY
	var bounds := Rect2(guide[0][0], Vector2.ZERO)
	for stroke in guide:
		for point in stroke:
			bounds = bounds.expand(point)
	var zoom := minf(GUIDE_WIDTH_FRACTION / maxf(bounds.size.x, 0.001),
		GUIDE_HEIGHT_FRACTION / maxf(bounds.size.y, 0.001))
	return Transform2D(0.0, Vector2.ONE * zoom, 0.0, Vector2(0.5, 0.5) - bounds.get_center() * zoom)


func _local_points(stroke: PackedVector2Array) -> PackedVector2Array:
	return _ink_points(_guide_fit * stroke)


func _ink_points(stroke: PackedVector2Array) -> PackedVector2Array:
	# Captured points stay in the physical square's normalized space, including on resize.
	var surface := _surface()
	var points := PackedVector2Array()
	for point in stroke:
		points.append(surface.position + point * surface.size)
	return points


func _draw() -> void:
	var guide_width := clampf(_surface().size.x * 0.009, 3.0, 6.0)
	for guide_stroke in _guide:
		var stroke := _local_points(guide_stroke)
		for point in range(1, stroke.size()):
			draw_dashed_line(stroke[point - 1], stroke[point], GUIDE_COLOR, guide_width, guide_width * 2.6, true, true)
	for stroke in _strokes:
		_draw_ink(stroke)
	_draw_ink(_current)


func _draw_brush() -> void:
	# The mouse-transparent child renders over both the guide and player ink.
	var radius := _ink_width() * 0.5
	var rim := radius * 0.26
	_brush_overlay.draw_circle(Vector2.ZERO, radius, BRUSH_FILL, true, -1.0, true)
	_brush_overlay.draw_arc(Vector2.ZERO, radius - rim, 0.0, TAU, 32, BRUSH_EDGE, rim * 2.0, true)
	_brush_overlay.draw_arc(Vector2.ZERO, radius - rim * 1.5, 0.0, TAU, 32, BRUSH_OUTLINE, rim, true)


func _draw_ink(stroke: PackedVector2Array) -> void:
	if stroke.is_empty():
		return
	var points := _ink_points(stroke)
	var width := _ink_width()
	for index in range(1, points.size()):
		draw_line(points[index - 1], points[index], INK_COLOR, width, true)
	for point in points:
		draw_circle(point, width * 0.5, INK_COLOR, true, -1.0, true)
