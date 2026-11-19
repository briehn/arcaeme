extends Control

const CombatView = preload("res://scripts/combat.gd")
const CoopRunState = preload("res://scripts/run/coop_run_state.gd")
const NetworkSession = preload("res://scripts/network/network_coop_session.gd")
const WrappedTextButton = preload("res://scripts/ui/wrapped_text_button.gd")
const COMBAT_SCENE = preload("res://scenes/combat.tscn")
const STATUS_ENCOUNTER = preload("res://resources/prototype/status_playtest/encounter.tres")

@onready var session: NetworkSession = $Session
@onready var setup_controls: HFlowContainer = %Controls
@onready var port_field: SpinBox = %Port
@onready var party_size_field: OptionButton = %PartySize
@onready var short_run_field: CheckBox = %ShortRun
@onready var status_playtest_field: CheckBox = %StatusPlaytest
@onready var default_encounter := session.encounter
@onready var status_label: Label = %ConnectionStatus
@onready var roster_label: Label = %PartyRoster
@onready var host_button: Button = %HostButton
@onready var join_button: Button = %JoinButton
@onready var leave_button: Button = %LeaveButton
@onready var run_stage_label: Label = %RunStage
@onready var reward_panel: MarginContainer = %RewardPanel
@onready var reward_status: Label = %RewardStatus
@onready var reward_progress: Label = %RewardProgress
@onready var reward_choices: VBoxContainer = %RewardChoices
@onready var skip_reward_button: Button = %SkipReward
@onready var combat_slot: Control = %CombatSlot

var _combat: CombatView


func _ready() -> void:
	port_field.value = NetworkSession.DEFAULT_PORT
	for size in range(NetworkSession.MIN_PARTY_SIZE, NetworkSession.MAX_PARTY_SIZE + 1):
		party_size_field.add_item(str(size), size)
	party_size_field.select(0)
	short_run_field.toggled.connect(_on_short_run_toggled)
	status_playtest_field.toggled.connect(_on_status_playtest_toggled)
	_combat = COMBAT_SCENE.instantiate()
	_combat.configure_network()
	_combat.network_card_requested.connect(session.submit_card)
	_combat.network_end_turn_requested.connect(session.submit_end_turn)
	combat_slot.add_child(_combat)
	session.changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	status_label.text = session.message
	var connected_or_waiting := session.status in [NetworkSession.Status.HOSTING, NetworkSession.Status.JOINING,
		NetworkSession.Status.WAITING, NetworkSession.Status.ACTIVE]
	setup_controls.visible = session.status != NetworkSession.Status.ACTIVE
	host_button.disabled = connected_or_waiting
	join_button.disabled = connected_or_waiting
	port_field.editable = not connected_or_waiting
	party_size_field.disabled = connected_or_waiting
	short_run_field.disabled = connected_or_waiting
	status_playtest_field.disabled = connected_or_waiting or short_run_field.button_pressed
	roster_label.visible = session.party_size > 0
	if roster_label.visible:
		roster_label.text = "%d/%d connected" % [session.connected_players.size(), session.party_size]
		if not session.connected_players.is_empty():
			roster_label.text += " · " + ", ".join(session.connected_players)
		if connected_or_waiting:
			party_size_field.select(party_size_field.get_item_index(session.party_size))
	leave_button.text = "Disconnect and Back to Menu" if connected_or_waiting else "Back to Menu"
	_refresh_session_view()


func _refresh_session_view() -> void:
	var stage: String = session.snapshot.get("run_stage", "")
	var stage_title := ""
	match stage:
		CoopRunState.OPENING:
			stage_title = "Opening Encounter"
		CoopRunState.REWARD:
			stage_title = "Choose a Card Reward"
		CoopRunState.BOSS:
			stage_title = "Boss"
		CoopRunState.VICTORY:
			stage_title = "Run Victory"
		CoopRunState.DEFEAT:
			stage_title = "Run Defeat"
	run_stage_label.visible = not stage_title.is_empty()
	run_stage_label.text = "Network Short Run Prototype  /  %s" % stage_title
	if stage == CoopRunState.REWARD:
		combat_slot.hide()
		_refresh_rewards()
		return
	if reward_panel.visible:
		reward_panel.hide()
		_clear_reward_choices()
	if session.snapshot.is_empty():
		_combat.clear_network_view()
		combat_slot.hide()
	else:
		var run_finished := stage == CoopRunState.VICTORY or stage == CoopRunState.DEFEAT
		_combat.display_network_snapshot(session.snapshot, session.can_submit() and not run_finished)
		combat_slot.show()


func _refresh_rewards() -> void:
	var opening_panel := not reward_panel.visible
	reward_panel.show()
	reward_progress.text = "%d/%d reward decisions submitted" % [session.snapshot["reward_ready"], session.party_size]
	var connected := session.status == NetworkSession.Status.ACTIVE
	var submitted: bool = session.snapshot["reward_submitted"]
	var choosing := connected and not submitted
	if not connected:
		reward_status.text = "The session ended."
	elif submitted:
		reward_status.text = "Reward decision submitted. The boss begins when everyone is ready."
	else:
		reward_status.text = "Choose one provisional Battle Mage card for your run deck, or skip."
	skip_reward_button.visible = choosing
	if not choosing:
		_clear_reward_choices()
		return
	if reward_choices.get_child_count() == 0:
		for card: Dictionary in session.snapshot["reward_options"]:
			var button := WrappedTextButton.new()
			button.text = "%s  ·  %d Mana\n%s" % [card["name"], card["cost"], card["description"]]
			button.custom_minimum_size.y = 56
			button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			button.pressed.connect(session.submit_reward.bind(card["id"]))
			reward_choices.add_child(button)
	var input_allowed := session.can_submit()
	for button: Button in reward_choices.get_children():
		button.disabled = not input_allowed
	skip_reward_button.disabled = not input_allowed
	if opening_panel and input_allowed:
		var focus_target: Button = reward_choices.get_child(0) if reward_choices.get_child_count() > 0 else skip_reward_button
		focus_target.grab_focus()


func _clear_reward_choices() -> void:
	for choice in reward_choices.get_children():
		reward_choices.remove_child(choice)
		choice.queue_free()


func _on_short_run_toggled(enabled: bool) -> void:
	host_button.text = "Host Short Run" if enabled else "Host Encounter"
	if enabled:
		status_playtest_field.button_pressed = false
	status_playtest_field.disabled = enabled


func _on_status_playtest_toggled(enabled: bool) -> void:
	session.encounter = STATUS_ENCOUNTER if enabled else default_encounter


func _on_host_pressed() -> void:
	session.host(int(port_field.value), party_size_field.get_selected_id(), short_run_field.button_pressed)


func _on_join_pressed() -> void:
	session.join(int(port_field.value))


func _on_skip_reward_pressed() -> void:
	session.submit_reward("")


func _on_leave_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")
