extends RefCounted

const WrappedTextButton = preload("res://scripts/ui/wrapped_text_button.gd")
const ART_PATHS := {
	"Normal Encounter": "res://assets/portals/portal_normal.png",
	"Elite Encounter": "res://assets/portals/portal_elite.png",
	"Boss Encounter": "res://assets/portals/portal_boss.png",
}
const ART_HEIGHT := 106.0


static func make(option: Dictionary) -> Button:
	var button := WrappedTextButton.new()
	button.custom_minimum_size.x = 246
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_color_override("font_color", Color("#f1e8ff"))
	button.add_theme_color_override("font_disabled_color", Color("#f1e8ff"))
	button.add_theme_stylebox_override("hover", _frame(Color("#35284c"), Color("#b39cde")))
	button.add_theme_stylebox_override("pressed", _frame(Color("#463353"), Color("#f7d295")))
	button.add_theme_stylebox_override("focus", _frame(Color.TRANSPARENT, Color("#f7d295")))
	button.set_meta(&"portal_id", String(option.id))
	var branches := PackedStringArray()
	for branch: Dictionary in option.branches:
		branches.append(branch.type)
	var preview := "No further portals" if branches.is_empty() else "Next portals: " + " / ".join(branches)
	button.text = "%s\n%s" % [option.type, preview]
	var art := TextureRect.new()
	art.name = "PortalArt"
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.anchor_right = 1.0
	art.offset_left = 8.0
	art.offset_right = -8.0
	art.offset_top = 4.0
	art.offset_bottom = ART_HEIGHT
	var art_path: String = ART_PATHS.get(option.type, "")
	if not art_path.is_empty() and ResourceLoader.exists(art_path, "Texture2D"):
		art.texture = load(art_path) as Texture2D
	if art.texture == null:
		art.draw.connect(func():
			var center := art.size * 0.5
			art.draw_arc(center, 43, 0, TAU, 64, Color("#b39cde"), 3.0, true)
			art.draw_arc(center, 36, 0, TAU, 64, Color("#705995"), 1.0, true))
		art.resized.connect(art.queue_redraw)
	button.add_child(art)
	var voters := Label.new()
	voters.name = "PortalVoters"
	voters.mouse_filter = Control.MOUSE_FILTER_IGNORE
	voters.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	voters.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	voters.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	voters.add_theme_font_size_override("font_size", 14)
	voters.add_theme_color_override("font_color", Color("#f7d295"))
	voters.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	voters.offset_left = 8.0
	voters.offset_right = -8.0
	voters.offset_top = -44.0
	voters.offset_bottom = -4.0
	button.add_child(voters)
	show_votes(button, {})
	return button


static func show_votes(button: Button, votes: Dictionary) -> void:
	var names := PackedStringArray()
	for mage in votes:
		if votes[mage] == button.get_meta(&"portal_id"):
			names.append(String(mage))
	var label := button.get_node("PortalVoters") as Label
	var caption := " · ".join(names)
	if label.text == caption and button.has_theme_stylebox_override("normal"):
		return
	label.text = caption
	var frame := _frame(Color(0.09, 0.06, 0.15, 0.57), Color(0.63, 0.52, 0.77, 0.45)) if names.is_empty() \
		else _frame(Color("#42334d"), Color("#f7d295"))
	button.add_theme_stylebox_override("normal", frame)
	button.add_theme_stylebox_override("disabled", frame)


static func _frame(fill: Color, edge: Color) -> StyleBoxFlat:
	var frame := StyleBoxFlat.new()
	frame.bg_color = fill
	frame.border_color = edge
	frame.set_border_width_all(1)
	frame.set_corner_radius_all(12)
	frame.content_margin_left = 12
	frame.content_margin_right = 12
	frame.content_margin_top = ART_HEIGHT + 4
	frame.content_margin_bottom = 46
	return frame
