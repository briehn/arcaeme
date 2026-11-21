extends Control

const CardData = preload("res://scripts/combat/card_data.gd")
const CastingPacing = preload("res://scripts/run/casting_pacing.gd")
const CoopRunState = preload("res://scripts/run/coop_run_state.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const CombatView = preload("res://scripts/combat.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const MajorArcana = preload("res://scripts/run/major_arcana.gd")
const PacingExperiment = preload("res://scripts/run/pacing_experiment.gd")
const PacingVariantPicker = preload("res://scripts/ui/pacing_variant_picker.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const RunState = preload("res://scripts/run/run_state.gd")
const SpellDrawingSettings = preload("res://scripts/combat/spell_drawing_settings.gd")
const WrappedTextButton = preload("res://scripts/ui/wrapped_text_button.gd")
const COMBAT_SCENE = preload("res://scenes/combat.tscn")
const LOCAL_MAGES: Array[StringName] = [&"Battle Mage 1", &"Battle Mage 2"]

@export var run_data: RunData
@export var enable_pacing_variants := false
@export var local_coop := false
var spell_drawing: SpellDrawingSettings
var bypass_drawing := false

@onready var run_panel: MarginContainer = %RunPanel
@onready var heading: Label = %Heading
@onready var run_status: Label = %RunStatus
@onready var message: Label = %Message
@onready var choices: BoxContainer = %Choices
@onready var deck_title: Label = %DeckTitle
@onready var deck_list: RichTextLabel = %DeckList
@onready var back_button: Button = %RunBackButton
@onready var pacing_controls: HBoxContainer = %PacingControls
@onready var pacing_variant_field: PacingVariantPicker = %PacingVariant
@onready var _pacing_template := run_data

var _run: RunState
var _local_run: CoopRunState
var _combat_view: CombatView
var _local_choice_index := 0
var _local_choice_revealed := false
var _casting_pacing: CastingPacing


func _ready() -> void:
	if spell_drawing != null and not bypass_drawing and OS.is_debug_build():
		_casting_pacing = CastingPacing.new(LOCAL_MAGES.size() if local_coop else 1)
		heading.mouse_filter = Control.MOUSE_FILTER_PASS
	pacing_variant_field.item_selected.connect(_on_pacing_variant_selected)
	if not run_data.title.is_empty():
		$RunPanel/Layout/Title.text = run_data.title
	if local_coop:
		_local_run = CoopRunState.new(run_data, LOCAL_MAGES, null, spell_drawing, bypass_drawing)
		if _local_run.stage == CoopRunState.ARCANA:
			_render_panel()
		else:
			_show_local_combat()
		return
	_run = RunState.new(run_data, spell_drawing, bypass_drawing)
	_render_panel()


func _render_panel(focus_choice := true) -> void:
	for choice in choices.get_children():
		choices.remove_child(choice)
		choice.queue_free()
	if local_coop:
		_render_local_panel()
	else:
		_render_solo_panel()
	if _casting_pacing != null:
		heading.tooltip_text = _casting_pacing.tooltip()
	run_panel.show()
	if focus_choice:
		var focus_target: Button = choices.get_child(0) if choices.get_child_count() > 0 else back_button
		focus_target.grab_focus()


func _render_solo_panel() -> void:
	pacing_controls.visible = enable_pacing_variants and _run.stage == RunState.Stage.ROUTE
	message.text = ""
	match _run.stage:
		RunState.Stage.ARCANA:
			heading.text = "Choose a Major Arcana"
			message.text = "Choose one provisional Arcana for this run, or skip."
			_add_arcana_choices(_run.arcana_options(), _submit_solo_arcana)
		RunState.Stage.ROUTE:
			heading.text = "Choose an opening encounter"
			message.text = "Provisional encounter stats"
			if run_data.portal_enabled:
				heading.text = "Begin the portal route"
			elif _multi_enemy_route():
				heading.text = "Choose to begin the fixed route"
			for encounter in run_data.opening_encounters:
				_add_choice("%s\n%s" % [encounter.enemy_name, _encounter_preview(encounter)],
					_choose_opening.bind(encounter.enemy_id))
		RunState.Stage.NEXT_READY, RunState.Stage.BOSS_READY:
			heading.text = "Ready for the boss" if run_data.title.is_empty() else "Ready for the final encounter"
			var next := _run.next_encounter()
			if _multi_enemy_route():
				heading.text = "Ready for %s" % _encounter_title(_run.encounter_id + 1, next)
			var reward := _run.selected_reward
			message.text = "Added %s to your run deck." % reward.display_name if reward != null else "Reward skipped."
			_add_choice("Fight %s\n%s" % [next.enemy_name, _encounter_preview(next)], _start_next)
		RunState.Stage.VICTORY:
			heading.text = "Run Victory"
			message.text = "You defeated %s and completed the prototype run." % _run.active_encounter.enemy_name
		RunState.Stage.DEFEAT:
			heading.text = "Run Defeat"
			message.text = "%s ended your run." % _run.active_encounter.enemy_name
	run_status.text = "Battle Mage  ·  HP %d/%d  ·  Run seed %d" % [_run.current_hp, _run.max_hp, _run.run_seed]
	if _multi_enemy_route() and _run.encounter_id > 0:
		run_status.text += "  ·  " + _encounter_title(_run.encounter_id, _run.active_encounter)
	_append_arcana_name(_run.selected_arcana)
	_render_deck(_run.deck_cards())


func _render_local_panel() -> void:
	deck_title.hide()
	deck_list.hide()
	deck_title.text = ""
	deck_list.text = ""
	if _local_run.stage == CoopRunState.ARCANA:
		_render_local_arcana()
		return
	run_status.text = _encounter_title(_local_run.encounter_id, _local_run.active_encounter)
	for mage in _local_run.active_combat.players.values():
		run_status.text += "\n%s  ·  HP %d/%d" % [mage.id, mage.hp, mage.max_hp]
	match _local_run.stage:
		CoopRunState.VICTORY:
			heading.text = "Run Victory"
			message.text = "Your party defeated %s and completed the prototype run." % _local_run.active_encounter.enemy_name
		CoopRunState.DEFEAT:
			heading.text = "Run Defeat"
			message.text = "%s ended your run." % _local_run.active_encounter.enemy_name


func _render_local_arcana() -> void:
	var player := LOCAL_MAGES[_local_choice_index]
	var view := _local_run.view_fields(player)
	run_status.text = "%d/%d Arcana decisions submitted" % [view.arcana_ready, LOCAL_MAGES.size()]
	heading.text = "Choose a Major Arcana"
	if _local_choice_revealed:
		message.text = "%s: choose one provisional Arcana for this run, or skip." % player
		_add_arcana_choices(view.arcana_options, _submit_local_arcana.bind(player))
	else:
		message.text = "Pass controls to %s." % player
		_add_choice("Show %s Arcana" % player, _show_local_choice.bind(player, 0, CoopRunState.ARCANA))


func _add_arcana_choices(options: Array, submit: Callable) -> void:
	for option: Dictionary in options:
		_add_choice("%s\n%s" % [option.name, option.description], submit.bind(StringName(option.id)))
	_add_choice("Skip Arcana", submit.bind(&""))


func _append_arcana_name(id: StringName) -> void:
	if id != &"":
		run_status.text += "\nMajor Arcana: " + String(MajorArcana.view(id).name)


func _submit_solo_arcana(id: StringName) -> void:
	if _run.submit_arcana(id):
		_render_panel()


func _show_local_choice(player: StringName, encounter_id: int, stage: String) -> void:
	if (_local_run.stage == stage and not _local_choice_revealed
			and _local_run.encounter_id == encounter_id and LOCAL_MAGES[_local_choice_index] == player):
		_local_choice_revealed = true
		if stage == CoopRunState.REWARD:
			_render_intermission()
		else:
			_render_panel()


func _submit_local_arcana(id: StringName, player: StringName) -> void:
	if (not _local_choice_revealed or _local_run.stage != CoopRunState.ARCANA
			or LOCAL_MAGES[_local_choice_index] != player or not _local_run.submit_arcana(player, id)):
		return
	_advance_local_choice(CoopRunState.ARCANA)


func _submit_local_reward(card_id: String, player: StringName, encounter_id: int) -> void:
	if (not _local_choice_revealed or _local_run.stage != CoopRunState.REWARD
			or _local_run.encounter_id != encounter_id or LOCAL_MAGES[_local_choice_index] != player):
		return
	if not _local_run.submit_reward(player, StringName(card_id)):
		return
	_advance_local_choice(CoopRunState.REWARD)


func _submit_solo_portal(portal_id: String) -> void:
	if _run.submit_portal(StringName(portal_id)):
		_show_solo_combat("Encounter")


func _submit_local_portal(portal_id: String, player: StringName, encounter_id: int) -> void:
	if (_local_run.stage != CoopRunState.PORTAL or _local_run.encounter_id != encounter_id
			or LOCAL_MAGES[_local_choice_index] != player or not _local_run.submit_portal(player, StringName(portal_id))):
		return
	_advance_local_choice(CoopRunState.PORTAL)


func _advance_local_choice(stage: String) -> void:
	_local_choice_revealed = false
	if _local_run.stage == stage:
		_local_choice_index += 1
		if stage == CoopRunState.ARCANA:
			_render_panel()
		else:
			_render_intermission()
	else:
		_local_choice_index = 0
		if _local_run.stage == CoopRunState.PORTAL:
			_render_intermission()
		else:
			_show_local_combat()


func _on_pacing_variant_selected(_index: int) -> void:
	if not enable_pacing_variants or _run.stage != RunState.Stage.ROUTE:
		return
	var variant := pacing_variant_field.selected_variant()
	run_data = _pacing_template if variant == PacingExperiment.VariantKind.BASELINE \
		else PacingExperiment.make_run(_pacing_template, variant, 1)
	_run = RunState.new(run_data, spell_drawing, bypass_drawing)
	_render_panel(false)


func _encounter_preview(encounter: EncounterData) -> String:
	if not encounter.enemies.is_empty():
		var enemies := PackedStringArray()
		for enemy in encounter.enemies:
			enemies.append("%s (%d HP)" % [enemy.display_name, enemy.max_hp])
		return "  ·  ".join(enemies)
	if encounter.enemy_attack_pattern.is_empty():
		return "%d HP  ·  Attacks for %d" % [encounter.enemy_max_hp, encounter.enemy_attack]
	var attacks := PackedStringArray()
	for damage: int in encounter.enemy_attack_pattern:
		attacks.append(str(maxi(damage, 0)))
	return "%d HP  ·  Base attack cycle %s" % [encounter.enemy_max_hp, " → ".join(attacks)]


func _render_deck(deck: Array[CardData]) -> void:
	deck_title.text = "Run deck  ·  %d cards" % deck.size()
	deck_list.text = _deck_text(deck)


func _deck_text(deck: Array[CardData]) -> String:
	var copies: Dictionary[CardData, int] = {}
	for card in deck:
		copies[card] = copies.get(card, 0) + 1
	var lines := PackedStringArray()
	for card: CardData in copies:
		lines.append("%d × %s" % [copies[card], card.display_name])
	return "\n".join(lines)


func _add_choice(label: String, action: Callable) -> void:
	var button := WrappedTextButton.new()
	button.text = label
	button.custom_minimum_size.y = 56
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.pressed.connect(action)
	choices.add_child(button)


func _choose_opening(encounter_id: StringName) -> void:
	if _run.choose_opening(encounter_id):
		_show_solo_combat("Opening Encounter")


func _submit_solo_reward(card_id: String) -> void:
	var accepted := _run.skip_reward() if card_id.is_empty() else _run.take_reward(StringName(card_id))
	if not accepted:
		return
	if _run.stage == RunState.Stage.PORTAL:
		_render_intermission()
	else:
		_remove_combat()
		_render_panel()


func _start_next() -> void:
	if _run.start_next_encounter():
		_show_solo_combat("Boss" if run_data.title.is_empty() else "Final Encounter")


func _multi_enemy_route() -> bool:
	return not run_data.intermediate_encounters.is_empty()


func _encounter_title(index: int, encounter: EncounterData) -> String:
	var label := "Boss: " + encounter.enemy_name if index == run_data.encounter_count() else encounter.enemy_name
	return "Encounter %d of %d  ·  %s" % [index, run_data.encounter_count(), label]


func _show_solo_combat(stage_title: String) -> void:
	if _multi_enemy_route():
		stage_title = _encounter_title(_run.encounter_id, _run.active_encounter)
	_show_combat(_run.active_combat, _run.active_encounter, stage_title, _run.encounter_id)


func _show_local_combat() -> void:
	_show_combat(_local_run.active_combat, _local_run.active_encounter,
		_encounter_title(_local_run.encounter_id, _local_run.active_encounter), _local_run.encounter_id)


func _show_combat(combat: CombatState, encounter: EncounterData, stage_title: String, index: int) -> void:
	_remove_combat()
	run_panel.hide()
	_combat_view = COMBAT_SCENE.instantiate()
	var run_title := "Prototype Run" if run_data.title.is_empty() else run_data.title
	_combat_view.configure_run(combat, encounter, "%s  /  %s" % [run_title, stage_title])
	_combat_view.spell_drawing = spell_drawing
	_combat_view.bypass_drawing = bypass_drawing
	if _casting_pacing != null:
		_casting_pacing.begin_encounter(index)
		_combat_view.drawing_prompt_opened.connect(_casting_pacing.prompt_opened.bind(index))
		_combat_view.drawing_attempt_finished.connect(_casting_pacing.attempt_finished.bind(index))
	_combat_view.encounter_finished.connect(_finish_encounter)
	add_child(_combat_view)


func _finish_encounter(combat: CombatState) -> void:
	if local_coop:
		if (combat != _local_run.active_combat or _combat_view == null
				or combat.phase not in [CombatState.Phase.VICTORY, CombatState.Phase.DEFEAT]):
			return
		_local_run.observe_combat_result()
		_local_choice_index = 0
		_local_choice_revealed = false
	elif not _run.finish_combat(combat):
		return
	var rewarding := _local_run.stage == CoopRunState.REWARD if local_coop else _run.stage == RunState.Stage.REWARD
	if rewarding:
		_render_intermission()
	else:
		_remove_combat()
		_render_panel()


func _render_intermission() -> void:
	if not local_coop:
		if _run.stage == RunState.Stage.PORTAL:
			_combat_view.show_encounter_portals(_run.portal_options(), {}, "Choose a portal", _submit_solo_portal, true)
			return
		var options: Array[Dictionary] = []
		for card: CardData in _run.reward_options():
			options.append({"name": card.display_name, "cost": card.mana_cost,
				"description": card.description(), "id": String(card.id)})
		var status := "Choose a card for your run deck, or skip."
		if run_data.portal_enabled:
			status += " Your portals open after this decision."
		elif _run.next_encounter() != null:
			status += " Next: %s." % _run.next_encounter().enemy_name
		_combat_view.open_reward_overlay().show_rewards("Victory · Card reward", status, options,
			_submit_solo_reward, true, Callable(), "", _deck_text(_run.deck_cards()))
		return
	var player := LOCAL_MAGES[_local_choice_index]
	var view := _local_run.view_fields(player)
	var index := _local_run.encounter_id
	if _local_run.stage == CoopRunState.PORTAL:
		var status := "%s: choose a portal · %d/%d choices submitted" % [player, view.portal_ready, LOCAL_MAGES.size()]
		_combat_view.show_encounter_portals(view.portal_options, view.portal_votes, status,
			_submit_local_portal.bind(player, index), true)
		return
	var progress := "%d/%d decisions submitted" % [view.reward_ready, LOCAL_MAGES.size()]
	var transition := ("Portals open after every Mage decides." if view.get("portal_after_reward", false)
		else "Next: %s." % view.next_encounter_name)
	var overlay := _combat_view.open_reward_overlay()
	if _local_choice_revealed:
		overlay.show_rewards("Victory · Card reward", "%s: choose a card or skip. %s\n%s" % [player, transition, progress],
			view.reward_options, _submit_local_reward.bind(player, index), true,
			Callable(), "", _deck_text(_local_run.deck_cards(player)))
	else:
		overlay.show_rewards("Victory · Card reward", "Pass controls to %s. %s\n%s" % [player, transition, progress],
			[], Callable(), true, _show_local_choice.bind(player, index, CoopRunState.REWARD), "Show %s Reward" % player)


func _remove_combat() -> void:
	if _combat_view == null:
		return
	remove_child(_combat_view)
	_combat_view.queue_free()
	_combat_view = null


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")
