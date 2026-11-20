extends Control

const CombatView = preload("res://scripts/combat.gd")
const CoopRunState = preload("res://scripts/run/coop_run_state.gd")
const NetworkSession = preload("res://scripts/network/network_coop_session.gd")
const WrappedTextButton = preload("res://scripts/ui/wrapped_text_button.gd")
const CardExpansionPlaytest = preload("res://scripts/run/card_expansion_playtest.gd")
const EnemyPlaytestSelector = preload("res://scripts/ui/enemy_playtest_selector.gd")
const PacingExperiment = preload("res://scripts/run/pacing_experiment.gd")
const PacingVariantPicker = preload("res://scripts/ui/pacing_variant_picker.gd")
const COMBAT_SCENE = preload("res://scenes/combat.tscn")
const STATUS_ENCOUNTER = preload("res://resources/prototype/status_playtest/encounter.tres")
const MODIFIER_ENCOUNTER = preload("res://resources/prototype/modifier_playtest/encounter.tres")
const ENEMY_VARIETY_RUN = preload("res://resources/prototype/enemy_variety_run.tres")
const MULTI_ENEMY_RUN = preload("res://resources/prototype/multi_enemy_run.tres")

@onready var session: NetworkSession = $Session
@onready var setup_controls: HFlowContainer = %Controls
@onready var port_field: SpinBox = %Port
@onready var party_size_field: OptionButton = %PartySize
@onready var short_run_field: CheckBox = %ShortRun
@onready var enemy_variety_run_field: CheckBox = %EnemyVarietyRun
@onready var multi_enemy_run_field: CheckBox = %MultiEnemyRun
@onready var pacing_controls: HBoxContainer = %PacingControls
@onready var pacing_variant_field: PacingVariantPicker = %PacingVariant
@onready var status_playtest_field: CheckBox = %StatusPlaytest
@onready var modifier_playtest_field: CheckBox = %ModifierPlaytest
@onready var enemy_playtest_field: EnemyPlaytestSelector = %EnemyPlaytest
@onready var card_expansion_field: CheckBox = %CardExpansion
@onready var default_encounter := session.encounter
@onready var default_run_data := session.run_data
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
	enemy_variety_run_field.toggled.connect(_on_enemy_variety_run_toggled)
	multi_enemy_run_field.toggled.connect(_on_multi_enemy_run_toggled)
	status_playtest_field.toggled.connect(_on_status_playtest_toggled)
	modifier_playtest_field.toggled.connect(_on_modifier_playtest_toggled)
	enemy_playtest_field.item_selected.connect(_on_enemy_playtest_selected)
	card_expansion_field.toggled.connect(_on_card_expansion_toggled)
	_combat = COMBAT_SCENE.instantiate()
	_combat.configure_network()
	_combat.network_card_requested.connect(session.submit_card)
	_combat.network_end_turn_requested.connect(session.submit_end_turn)
	_combat.network_undo_ready_requested.connect(session.submit_undo_ready)
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
	enemy_variety_run_field.disabled = connected_or_waiting or not short_run_field.button_pressed
	multi_enemy_run_field.disabled = connected_or_waiting or not short_run_field.button_pressed
	pacing_variant_field.disabled = connected_or_waiting or not enemy_variety_run_field.button_pressed
	status_playtest_field.disabled = connected_or_waiting or short_run_field.button_pressed
	modifier_playtest_field.disabled = connected_or_waiting or short_run_field.button_pressed
	enemy_playtest_field.disabled = connected_or_waiting or short_run_field.button_pressed
	_refresh_card_expansion_option(connected_or_waiting)
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
	var configured_title: String = session.snapshot.get("run_title", "")
	var stage_title := ""
	match stage:
		CoopRunState.OPENING:
			stage_title = "Opening Encounter"
		CoopRunState.INTERMEDIATE:
			stage_title = "Encounter"
		CoopRunState.REWARD:
			stage_title = "Choose a Card Reward"
		CoopRunState.BOSS:
			stage_title = "Boss" if configured_title.is_empty() else "Final Encounter"
		CoopRunState.VICTORY:
			stage_title = "Run Victory"
		CoopRunState.DEFEAT:
			stage_title = "Run Defeat"
	run_stage_label.visible = not stage_title.is_empty()
	var run_title := "Network Short Run Prototype" if configured_title.is_empty() else configured_title
	var encounter_count: int = session.snapshot.get("encounter_count", 0)
	if encounter_count > 2:
		var index: int = session.snapshot["encounter_id"]
		var encounter_name: String = session.snapshot["enemy_name"]
		if stage == CoopRunState.BOSS:
			encounter_name = "Boss: " + encounter_name
		var encounter_title := "Encounter %d of %d  ·  %s" % [index, encounter_count, encounter_name]
		if stage in [CoopRunState.REWARD, CoopRunState.VICTORY, CoopRunState.DEFEAT]:
			stage_title += "  /  " + encounter_title
		else:
			stage_title = encounter_title
	run_stage_label.text = "%s  /  %s" % [run_title, stage_title]
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
		var configured_title: String = session.snapshot.get("run_title", "")
		var next_encounter := "boss" if configured_title.is_empty() else "final encounter"
		reward_status.text = "Reward decision submitted. The %s begins when everyone is ready." % next_encounter
	else:
		reward_status.text = "Choose one provisional Battle Mage card for your run deck, or skip."
	if connected and session.snapshot.get("encounter_count", 0) > 2:
		reward_status.text = ("Reward decision submitted." if submitted
			else "Choose one provisional Battle Mage card for your run deck, or skip.")
		reward_status.text += " Next: %s, after everyone's decision." % session.snapshot["next_encounter_name"]
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
	if enabled:
		status_playtest_field.set_pressed_no_signal(false)
		modifier_playtest_field.set_pressed_no_signal(false)
		enemy_playtest_field.select(0)
	else:
		enemy_variety_run_field.set_pressed_no_signal(false)
		multi_enemy_run_field.set_pressed_no_signal(false)
	enemy_variety_run_field.visible = enabled
	enemy_variety_run_field.disabled = not enabled
	multi_enemy_run_field.visible = enabled
	multi_enemy_run_field.disabled = not enabled
	status_playtest_field.disabled = enabled
	modifier_playtest_field.disabled = enabled
	enemy_playtest_field.disabled = enabled
	_select_encounter_fixture()
	if enabled:
		_refresh_host_button_text()
	else:
		_refresh_run_variant()


func _on_enemy_variety_run_toggled(enabled: bool) -> void:
	if enabled:
		multi_enemy_run_field.set_pressed_no_signal(false)
	_refresh_run_variant()


func _on_multi_enemy_run_toggled(enabled: bool) -> void:
	if enabled:
		enemy_variety_run_field.set_pressed_no_signal(false)
	_refresh_run_variant()


func _refresh_run_variant() -> void:
	var variety := enemy_variety_run_field.button_pressed
	if variety:
		session.run_data = ENEMY_VARIETY_RUN
	elif multi_enemy_run_field.button_pressed:
		session.run_data = MULTI_ENEMY_RUN
	else:
		session.run_data = default_run_data
	pacing_controls.visible = variety
	pacing_variant_field.disabled = not variety
	if not variety:
		pacing_variant_field.select(pacing_variant_field.get_item_index(PacingExperiment.VariantKind.BASELINE))
	_refresh_card_expansion_option()
	_refresh_host_button_text()


func _refresh_host_button_text() -> void:
	if multi_enemy_run_field.button_pressed:
		host_button.text = "Host Multi-Enemy Short Run"
	elif enemy_variety_run_field.button_pressed:
		host_button.text = "Host Enemy Variety Run"
	elif short_run_field.button_pressed:
		host_button.text = "Host Short Run"
	else:
		host_button.text = "Host Encounter"


func _on_status_playtest_toggled(enabled: bool) -> void:
	if enabled:
		modifier_playtest_field.set_pressed_no_signal(false)
		enemy_playtest_field.select(0)
	_select_encounter_fixture()


func _on_modifier_playtest_toggled(enabled: bool) -> void:
	if enabled:
		status_playtest_field.set_pressed_no_signal(false)
		enemy_playtest_field.select(0)
	_select_encounter_fixture()


func _on_enemy_playtest_selected(index: int) -> void:
	if index > 0:
		status_playtest_field.set_pressed_no_signal(false)
		modifier_playtest_field.set_pressed_no_signal(false)
	_select_encounter_fixture()


func _on_card_expansion_toggled(_enabled: bool) -> void:
	if not short_run_field.button_pressed:
		_select_encounter_fixture()


func _refresh_card_expansion_option(locked := false) -> void:
	var available := enemy_variety_run_field.button_pressed if short_run_field.button_pressed \
		else not (status_playtest_field.button_pressed or modifier_playtest_field.button_pressed)
	if not available:
		card_expansion_field.set_pressed_no_signal(false)
	card_expansion_field.visible = available
	card_expansion_field.disabled = locked or not available


func _select_encounter_fixture() -> void:
	_refresh_card_expansion_option()
	if status_playtest_field.button_pressed:
		session.encounter = STATUS_ENCOUNTER
	elif modifier_playtest_field.button_pressed:
		session.encounter = MODIFIER_ENCOUNTER
	else:
		var enemy_prototype := enemy_playtest_field.selected_encounter()
		session.encounter = enemy_prototype if enemy_prototype != null else default_encounter
		if card_expansion_field.button_pressed and not short_run_field.button_pressed:
			session.encounter = CardExpansionPlaytest.with_expansion_deck(session.encounter)


func _on_host_pressed() -> void:
	var party_size := party_size_field.get_selected_id()
	if enemy_variety_run_field.button_pressed:
		var variant := pacing_variant_field.selected_variant()
		session.run_data = ENEMY_VARIETY_RUN if variant == PacingExperiment.VariantKind.BASELINE \
			else PacingExperiment.make_run(ENEMY_VARIETY_RUN, variant, party_size)
		if card_expansion_field.button_pressed:
			session.run_data = CardExpansionPlaytest.with_expansion_run(session.run_data)
	session.host(int(port_field.value), party_size, short_run_field.button_pressed)


func _on_join_pressed() -> void:
	session.join(int(port_field.value))


func _on_skip_reward_pressed() -> void:
	session.submit_reward("")


func _on_leave_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")
