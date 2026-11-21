extends RefCounted

const WrappedTextButton = preload("res://scripts/ui/wrapped_text_button.gd")


static func make(option: Dictionary) -> Button:
	var button := WrappedTextButton.new()
	button.custom_minimum_size.y = 76
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var frame := StyleBoxFlat.new()
	frame.bg_color = Color("#281d39")
	frame.border_color = Color("#8870aa")
	frame.set_border_width_all(1)
	frame.set_corner_radius_all(6)
	frame.content_margin_left = 12
	frame.content_margin_right = 12
	frame.content_margin_top = 8
	frame.content_margin_bottom = 8
	button.add_theme_stylebox_override("normal", frame)
	var hover := frame.duplicate() as StyleBoxFlat
	hover.bg_color = Color("#3a2b50")
	hover.border_color = Color("#c5a8dd")
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_color_override("font_color", Color("#d9bcf0"))
	button.set_meta(&"portal_id", String(option.id))
	var branches := PackedStringArray()
	for branch: Dictionary in option.branches:
		branches.append(branch.type)
	var preview := "No further portals" if branches.is_empty() else "Next portals: " + " / ".join(branches)
	button.text = "%s\n%s" % [option.type, preview]
	return button
