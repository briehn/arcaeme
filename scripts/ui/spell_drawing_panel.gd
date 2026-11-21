extends Control

const RuneCanvas = preload("res://scripts/ui/rune_canvas.gd")
const NORMAL_TIME_COLOR := Color(0.98, 0.84, 0.56)
const LOW_TIME_COLOR := Color(1.0, 0.59, 0.56)

signal drawing_submitted(strokes: Array[PackedVector2Array])
signal cast_canceled
signal cast_expired

@onready var _card_title: Label = %CardTitle
@onready var _rune_name: Label = %RuneName
@onready var _time_label: Label = %TimeLabel
@onready var _canvas: RuneCanvas = %RuneCanvas
@onready var _clear_button: Button = %ClearButton
@onready var _cancel_button: Button = %CancelButton
@onready var _submit_button: Button = %SubmitButton

var _deadline_ms := 0


func _ready() -> void:
	set_process(false)
	resized.connect(_fit_surface)
	_cancel_button.pressed.connect(_cancel_cast)
	_clear_button.pressed.connect(_canvas.clear_strokes)
	_submit_button.pressed.connect(_submit_drawing)
	_canvas.strokes_changed.connect(_refresh_buttons)
	_fit_surface()


func open_cast(card_name: String, rune_name: String, guide: Array[PackedVector2Array], deadline_ms: int) -> void:
	_deadline_ms = deadline_ms
	_card_title.text = "Cast %s" % card_name
	_rune_name.text = rune_name
	_canvas.set_guide(guide)
	show()
	_fit_surface()
	_cancel_button.grab_focus()
	set_process(true)
	_process(0.0)


func close_cast() -> void:
	set_process(false)
	hide()
	_canvas.clear_strokes()


func _process(_delta: float) -> void:
	var remaining_ms := _deadline_ms - Time.get_ticks_msec()
	if remaining_ms <= 0:
		_expire_cast()
		return
	_time_label.text = "%0.1f s" % (ceilf(remaining_ms / 100.0) / 10.0)
	_time_label.add_theme_color_override(&"font_color",
		LOW_TIME_COLOR if remaining_ms < 1500 else NORMAL_TIME_COLOR)


func _fit_surface() -> void:
	# Leave room for the heading and actions at the smallest supported height.
	var side := clampf(minf(size.x - 64.0, size.y - 205.0), 160.0, 380.0)
	_canvas.custom_minimum_size = Vector2(side, side)


func _refresh_buttons() -> void:
	var ready_to_submit := _canvas.has_completed_strokes()
	_submit_button.disabled = not ready_to_submit
	var after_clear := NodePath("../SubmitButton") if ready_to_submit else NodePath("../CancelButton")
	var before_cancel := NodePath("../SubmitButton") if ready_to_submit else NodePath("../ClearButton")
	_clear_button.focus_next = after_clear
	_clear_button.focus_neighbor_right = after_clear
	_cancel_button.focus_previous = before_cancel
	_cancel_button.focus_neighbor_left = before_cancel


func _submit_drawing() -> void:
	if not visible or not _canvas.has_completed_strokes():
		return
	if Time.get_ticks_msec() >= _deadline_ms:
		_expire_cast()
		return
	var strokes := _canvas.completed_strokes()
	close_cast()
	drawing_submitted.emit(strokes)


func _cancel_cast() -> void:
	if visible:
		close_cast()
		cast_canceled.emit()


func _expire_cast() -> void:
	if visible:
		close_cast()
		cast_expired.emit()


func _input(event: InputEvent) -> void:
	if is_visible_in_tree() and event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		_cancel_cast()


func _unhandled_key_input(_event: InputEvent) -> void:
	if is_visible_in_tree():
		get_viewport().set_input_as_handled()
