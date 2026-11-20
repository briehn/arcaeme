extends Button

var _initial_minimum_height: float


func set_wrapped_text(value: String) -> void:
	if text == value:
		return
	text = value
	if is_node_ready():
		_fit_wrapped_text()


func _ready() -> void:
	_initial_minimum_height = custom_minimum_size.y
	resized.connect(_fit_wrapped_text)
	_fit_wrapped_text()


func _fit_wrapped_text() -> void:
	var padding := get_theme_stylebox("normal").get_minimum_size()
	var text_width := size.x - padding.x
	if text_width <= 0.0:
		return
	# Button's native minimum accounts for explicit newlines, but not width-dependent wrapping.
	var paragraph := TextParagraph.new()
	paragraph.width = text_width
	paragraph.break_flags = TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE
	paragraph.add_string(text, get_theme_font("font"), get_theme_font_size("font_size"))
	custom_minimum_size.y = maxf(_initial_minimum_height, ceilf(paragraph.get_size().y + padding.y))
