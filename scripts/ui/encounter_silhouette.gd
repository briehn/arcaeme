extends Control

const SEAT_COLORS := [Color("#c5b8f0"), Color("#aad5f2"), Color("#c4e5bd"), Color("#f2bdd5")]

var _kind := ""
var _active := false
var _alive := true
var _seat := 0
var _health := 1.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func display(kind: String, alive: bool, active := false, seat := 0) -> void:
	_kind = kind.to_lower()
	_active = active
	_alive = alive
	_seat = seat
	queue_redraw()


func set_health(current: int, maximum: int) -> void:
	_health = float(current) / maxi(1, maximum)
	queue_redraw()


func _draw() -> void:
	var radius := minf(size.x, size.y) * 0.45
	if radius <= 0.0:
		return
	var center := size * 0.5
	draw_set_transform(center, 0, Vector2.ONE * radius)
	var color: Color = SEAT_COLORS[(_seat - 1) % SEAT_COLORS.size()] if _seat > 0 else Color("#c5b8f0")
	if not _alive:
		color = Color("#9b90a7")
	draw_circle(Vector2.ZERO, 0.97, Color("#21182d"), true, -1, true)
	draw_arc(Vector2.ZERO, 0.96, 0, TAU, 36, Color("#f4d288") if _active else Color("#756788"), 0.065, true)
	if _kind == "mage":
		draw_set_transform(center)
		draw_circle(Vector2(0, -0.26 * radius), 0.24 * radius, color, true, -1, true)
		draw_set_transform(center, 0, Vector2.ONE * radius)
		_polygon([-0.23, -0.03, 0.23, -0.03, 0.59, 0.62, -0.59, 0.62], color)
		var font := get_theme_default_font()
		var number := str(_seat)
		var font_size := 32
		var text_width := font.get_string_size(number, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		draw_set_transform(center, 0, Vector2.ONE * 0.38)
		draw_string(font, Vector2(-text_width * 0.5, radius * 0.96), number, HORIZONTAL_ALIGNMENT_LEFT, -1,
			font_size, Color("#21182d"))
		draw_set_transform(center)
		var health_start := Vector2(-0.40, 0.76) * radius
		var health_end := Vector2(0.40, 0.76) * radius
		draw_line(health_start, health_end, Color("#665779"), maxf(2.0, radius * 0.065), true)
		if _health > 0.0:
			draw_line(health_start, health_start.lerp(health_end, minf(1.0, _health)),
				color, maxf(2.0, radius * 0.065), true)
	else:
		if _kind.contains("slime"):
			draw_set_transform(center)
			draw_circle(Vector2(0, 0.12 * radius), 0.55 * radius, color, true, -1, true)
			draw_set_transform(center, 0, Vector2.ONE * radius)
			draw_rect(Rect2(-0.55, 0.12, 1.1, 0.45), color)
		elif _kind.contains("goblin"):
			_polygon([-0.72, -0.32, -0.28, -0.18, 0, -0.55, 0.28, -0.18, 0.72, -0.32,
				0.46, 0.24, 0, 0.59, -0.46, 0.24], color)
		elif _kind.contains("treant"):
			_polygon([0, -0.75, 0.62, 0.18, 0.24, 0.18, 0.24, 0.65, -0.24, 0.65, -0.24, 0.18, -0.62, 0.18], color)
		elif _kind.contains("golem"):
			draw_rect(Rect2(-0.54, -0.47, 1.08, 0.99), color)
			draw_rect(Rect2(-0.35, -0.20, 0.7, 0.21), Color("#21182d"))
		elif _kind.contains("warden"):
			_polygon([-0.63, -0.56, 0.63, -0.56, 0.52, 0.2, 0, 0.69, -0.52, 0.2], color)
		else:
			_polygon([0, -0.69, 0.65, 0, 0, 0.69, -0.65, 0], color)
	if not _alive:
		draw_set_transform(center, 0, Vector2.ONE * radius)
		draw_line(Vector2(-0.63, 0.63), Vector2(0.63, -0.63), Color("#21182d"), 0.16, true)


func _polygon(coordinates: Array, color: Color) -> void:
	var points := PackedVector2Array()
	for index in range(0, coordinates.size(), 2):
		points.append(Vector2(coordinates[index], coordinates[index + 1]))
	draw_colored_polygon(points, color)
