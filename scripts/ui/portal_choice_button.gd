extends RefCounted

const WrappedTextButton = preload("res://scripts/ui/wrapped_text_button.gd")
const ART_PATHS := {
	"Normal Encounter": "res://assets/portals/portal_normal.png",
	"Elite Encounter": "res://assets/portals/portal_elite.png",
	"Boss Encounter": "res://assets/portals/portal_boss.png",
}
const ART_HEIGHT := 112.0
const GOLD := Color("#f7d295")
const FOCUS_COLOR := Color("#d3caff")
const HOVER_TINT := Color(1.17, 1.17, 1.17)


class PhysicalPortalButton extends WrappedTextButton:
	var _keyboard_input := false

	func _ready() -> void:
		super._ready()
		mouse_entered.connect(refresh_interaction)
		mouse_exited.connect(refresh_interaction)
		focus_entered.connect(refresh_interaction)
		focus_exited.connect(refresh_interaction)

	func _input(event: InputEvent) -> void:
		if not is_visible_in_tree():
			return
		var keyboard_input := _keyboard_input
		if event is InputEventMouse:
			keyboard_input = false
		elif not event is InputEventKey and not event is InputEventJoypadButton and not event is InputEventJoypadMotion:
			return
		elif (event.is_action_pressed("ui_left", true) or event.is_action_pressed("ui_right", true)
				or event.is_action_pressed("ui_up", true) or event.is_action_pressed("ui_down", true)
				or event.is_action_pressed("ui_focus_next") or event.is_action_pressed("ui_focus_prev")
				or event.is_action_pressed("ui_accept")):
			keyboard_input = true
		if keyboard_input != _keyboard_input:
			_keyboard_input = keyboard_input
			refresh_interaction()

	func refresh_interaction() -> void:
		var art := get_node("PortalArt") as TextureRect
		var frame := art.get_node("PortalKeyboardFocus") as Control
		art.self_modulate = HOVER_TINT if not _keyboard_input and not disabled and is_hovered() else Color.WHITE
		frame.visible = _keyboard_input and not disabled and has_focus()


static func make(option: Dictionary) -> WrappedTextButton:
	var button := PhysicalPortalButton.new()
	button.custom_minimum_size.x = 170
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_color_override("font_color", Color("#f1e8ff"))
	button.add_theme_color_override("font_disabled_color", Color("#f1e8ff"))
	var clear := StyleBoxEmpty.new()
	clear.content_margin_left = 4
	clear.content_margin_right = 4
	clear.content_margin_top = ART_HEIGHT + 4
	clear.content_margin_bottom = 38
	for state in ["normal", "disabled", "hover", "pressed"]:
		button.add_theme_stylebox_override(state, clear)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
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
	var frame := Control.new()
	frame.name = "PortalKeyboardFocus"
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.hide()
	frame.draw.connect(func(): _draw_focus_brackets(frame))
	frame.resized.connect(frame.queue_redraw)
	art.add_child(frame)
	var voters := Label.new()
	voters.name = "PortalVoters"
	voters.mouse_filter = Control.MOUSE_FILTER_IGNORE
	voters.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	voters.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	voters.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	voters.add_theme_font_size_override("font_size", 14)
	voters.add_theme_color_override("font_color", GOLD)
	voters.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	voters.offset_left = 8.0
	voters.offset_right = -8.0
	voters.offset_top = -37.0
	voters.offset_bottom = -3.0
	button.add_child(voters)
	show_votes(button, {})
	return button


static func size_to_battlefield(button: WrappedTextButton, view_width: float) -> void:
	var art_height := clampf(view_width * 0.111, ART_HEIGHT, 172)
	button.custom_minimum_size.x = clampf(view_width * 0.125, 170, 224)
	(button.get_node("PortalArt") as Control).offset_bottom = art_height
	button.get_theme_stylebox("normal").content_margin_top = art_height + 4
	button._fit_wrapped_text()


static func show_votes(button: Button, votes: Dictionary) -> void:
	(button as PhysicalPortalButton).refresh_interaction()
	var names := PackedStringArray()
	for mage in votes:
		if votes[mage] == button.get_meta(&"portal_id"):
			names.append(String(mage))
	var label := button.get_node("PortalVoters") as Label
	var caption := " · ".join(names)
	label.text = caption
	var tint := Color("#f1e8ff") if names.is_empty() else GOLD
	button.add_theme_color_override("font_color", tint)
	button.add_theme_color_override("font_disabled_color", tint)


static func _draw_focus_brackets(frame: Control) -> void:
	var center := frame.size * 0.5
	var half := Vector2(minf(frame.size.x * 0.4, frame.size.y * 0.40), frame.size.y * 0.44)
	var arm := 12.0
	for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		var point := center + corner * half
		frame.draw_line(point, point - Vector2(corner.x * arm, 0), FOCUS_COLOR, 2.0, true)
		frame.draw_line(point, point - Vector2(0, corner.y * arm), FOCUS_COLOR, 2.0, true)
