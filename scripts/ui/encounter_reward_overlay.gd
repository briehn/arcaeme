extends Control

const WrappedTextButton = preload("res://scripts/ui/wrapped_text_button.gd")
const CARD_ACCENTS: Array[Color] = [Color("#ad92e3"), Color("#8ec8df"), Color("#e6af93")]

var _submit: Callable
var _reveal: Callable
var _options: Array = []
var _deck_text := ""
var _enabled := false

@onready var _title: Label = %RewardTitle
@onready var _message: Label = %RewardStatus
@onready var _choices: HFlowContainer = %RewardChoices
@onready var _skip: Button = %SkipReward
@onready var _reveal_button: Button = %RevealReward
@onready var _deck_toggle: Button = %DeckToggle
@onready var _deck_list: Label = %DeckList


func _ready() -> void:
	_skip.pressed.connect(_submit_reward.bind(""))
	_reveal_button.pressed.connect(_reveal_reward)
	_deck_toggle.toggled.connect(_show_deck)
	for button in [_skip, _reveal_button, _deck_toggle]:
		_style_button(button, Color("#b69ddc"), false)


func show_rewards(title: String, message: String, options: Array, submit: Callable, enabled: bool,
		reveal: Callable = Callable(), reveal_text := "", deck_text := "") -> void:
	var new_view := (not visible or _options != options or _submit != submit or _reveal != reveal
		or _deck_text != deck_text)
	_title.text = title
	_message.text = message
	_submit = submit
	_reveal = reveal
	_enabled = enabled
	if new_view:
		_clear_choices()
		_options = options.duplicate(true) if submit.is_valid() else []
		for index in _options.size():
			_add_card(_options[index], index)
		_reset_deck(deck_text if submit.is_valid() else "")
		(%Scroll as ScrollContainer).scroll_vertical = 0
	_skip.visible = submit.is_valid()
	_skip.disabled = not enabled
	_reveal_button.visible = reveal.is_valid()
	_reveal_button.disabled = not enabled
	_reveal_button.text = reveal_text
	for button: Button in _choices.get_children():
		button.disabled = not enabled
	show()
	_set_modal_focus(new_view)


func close_rewards() -> void:
	hide()
	_clear_choices()
	_options.clear()
	_title.text = ""
	_message.text = ""
	_submit = Callable()
	_reveal = Callable()
	_enabled = false
	_skip.hide()
	_reveal_button.hide()
	_reveal_button.text = ""
	_reset_deck("")


func _add_card(card: Dictionary, index: int) -> void:
	var button := WrappedTextButton.new()
	button.custom_minimum_size = Vector2(218, 166)
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.add_theme_font_size_override("font_size", 17)
	button.text = "%s  ·  %d Mana\n\n%s" % [card.name, card.cost, card.description]
	_style_button(button, CARD_ACCENTS[index % CARD_ACCENTS.size()], true)
	button.pressed.connect(_submit_reward.bind(String(card.id)))
	_choices.add_child(button)


func _clear_choices() -> void:
	for choice in _choices.get_children():
		_choices.remove_child(choice)
		choice.queue_free()


func _reset_deck(text: String) -> void:
	_deck_text = text
	_deck_toggle.visible = not text.is_empty()
	_deck_toggle.set_pressed_no_signal(false)
	_show_deck(false)


func _show_deck(revealed: bool) -> void:
	_deck_toggle.text = "Hide run deck" if revealed else "View run deck"
	_deck_list.visible = revealed
	_deck_list.text = _deck_text if revealed else ""


func _submit_reward(id: String) -> void:
	if visible and _enabled and _submit.is_valid():
		_submit.call(id)


func _reveal_reward() -> void:
	if visible and _enabled and _reveal.is_valid():
		_reveal.call()


func _set_modal_focus(reset: bool) -> void:
	var controls: Array[Button] = []
	for button: Button in _choices.get_children() + [_reveal_button, _skip, _deck_toggle]:
		if button.visible and not button.disabled:
			controls.append(button)
	var previous := get_viewport().gui_get_focus_owner()
	if controls.is_empty():
		grab_focus()
		return
	for index in controls.size():
		var current := controls[index]
		var next := current.get_path_to(controls[(index + 1) % controls.size()])
		var prior := current.get_path_to(controls[posmod(index - 1, controls.size())])
		current.focus_next = next
		current.focus_previous = prior
		current.focus_neighbor_left = prior
		current.focus_neighbor_top = prior
		current.focus_neighbor_right = next
		current.focus_neighbor_bottom = next
	if reset or not controls.has(previous):
		controls[0].grab_focus()


func _input(event: InputEvent) -> void:
	if is_visible_in_tree() and event is InputEventKey:
		var focused := get_viewport().gui_get_focus_owner()
		if focused == null or focused == self or not is_ancestor_of(focused):
			get_viewport().set_input_as_handled()


func _style_button(button: Button, accent: Color, card: bool) -> void:
	button.add_theme_color_override("font_color", Color("#f4ecff"))
	button.add_theme_color_override("font_hover_color", Color("#fff8ff"))
	button.add_theme_color_override("font_disabled_color", Color("#b1a5bb"))
	button.add_theme_stylebox_override("normal", _frame(Color("#251d36"), accent.darkened(0.24), card))
	button.add_theme_stylebox_override("hover", _frame(Color("#37294c"), accent, card))
	button.add_theme_stylebox_override("pressed", _frame(Color("#1a1427"), accent, card))
	button.add_theme_stylebox_override("disabled", _frame(Color("#1b1628"), Color("#695e76"), card))
	var focus := _frame(Color.TRANSPARENT, Color("#ffe0a6"), false)
	focus.set_border_width_all(2)
	button.add_theme_stylebox_override("focus", focus)


func _frame(fill: Color, edge: Color, card: bool) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = edge
	box.set_border_width_all(1)
	box.border_width_top = 4 if card else 1
	box.set_corner_radius_all(9 if card else 5)
	box.content_margin_left = 16
	box.content_margin_right = 16
	box.content_margin_top = 16 if card else 6
	box.content_margin_bottom = 16 if card else 6
	return box
