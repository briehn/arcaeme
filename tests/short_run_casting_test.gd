extends SceneTree

const BattleMagePool = preload("res://scripts/run/battle_mage_pool_playtest.gd")
const CardData = preload("res://scripts/combat/card_data.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const CombatView = preload("res://scripts/combat.gd")
const CoopRunState = preload("res://scripts/run/coop_run_state.gd")
const MajorArcana = preload("res://scripts/run/major_arcana.gd")
const PortalRoute = preload("res://scripts/run/portal_route.gd")
const PrototypeRunView = preload("res://scripts/prototype_run.gd")
const RuneCanvas = preload("res://scripts/ui/rune_canvas.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const RunState = preload("res://scripts/run/run_state.gd")
const RuneTemplate = preload("res://scripts/combat/rune_template.gd")
const MAIN = preload("res://scenes/main.tscn")
const RUN = preload("res://scenes/prototype_run.tscn")
const ROUTE = preload("res://resources/prototype/multi_enemy_run.tres")
const SETTINGS = preload("res://resources/prototype/spell_drawing_settings.tres")
const ASTRA = preload("res://resources/prototype/cards/expansion/astral_salvo.tres")
const BLOCK = preload("res://resources/prototype/cards/basic_block.tres")
const BOOSTER = preload("res://resources/prototype/cards/spell_ink_booster.tres")
const GUARD = preload("res://resources/prototype/cards/arcane_guard.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const TWIN = preload("res://resources/prototype/cards/pool_expansion/twin_sigil.tres")
const SOLO := RunState.PLAYER_ID
const FIRST := &"Battle Mage 1"
const SECOND := &"Battle Mage 2"

var _viewport: SubViewport
var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run_tests.call_deferred()


func _run_tests() -> void:
	await _test_main_launch()
	await _test_standalone_catalogue_launch()
	_test_seeded_draws()
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(1280, 720)
	root.add_child(_viewport)
	await _test_solo_portal_run()
	await _test_local_run()
	await _test_local_victory()
	await _test_abandoned_cast()
	_viewport.queue_free()
	await _settle()
	print("Short-run casting: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures != 0))


func _test_main_launch() -> void:
	for mode in [&"solo", &"local_bypass", &"disabled"]:
		change_scene_to_packed(MAIN)
		await scene_changed
		var menu := current_scene
		var drawing: bool = mode != &"disabled"
		(menu.get_node("%SpellDrawing") as CheckBox).button_pressed = drawing
		(menu.get_node("%SpellDrawingBypass") as CheckBox).button_pressed = mode == &"local_bypass"
		(menu.get_node("%PortalPrototype") as CheckBox).button_pressed = mode == &"solo"
		(menu.get_node("%BattleMagePool") as CheckBox).button_pressed = mode == &"solo"
		var launch := "%StartLocalMultiEnemyRunButton" if mode == &"local_bypass" else "%StartMultiEnemyRunButton"
		(menu.get_node(launch) as Button).pressed.emit()
		await scene_changed
		var run := current_scene as PrototypeRunView
		var expected_deck := ROUTE.starting_deck.duplicate()
		if drawing:
			expected_deck.append(BOOSTER)
		_check(run != null and run.run_data.starting_deck == expected_deck
			and run.run_data.portal_enabled == (mode == &"solo")
			and (run.spell_drawing != null) == drawing and run.bypass_drawing == (mode == &"local_bypass"),
			"the main menu launches %s with the expected route, deck, and drawing settings" % mode)
		if mode == &"solo":
			_check(ASTRA in run.run_data.eligible_rewards(RunData.BATTLE_MAGE) and ASTRA not in run.run_data.starting_deck,
				"the pilot composes with the expanded rewards rather than replacing the starter deck")
		elif mode == &"local_bypass":
			_check(run._combat_view != null and not run._combat_view.has_node("SpellDrawingPanel")
				and run._local_run.deck_cards(FIRST) == expected_deck and run._local_run.deck_cards(SECOND) == expected_deck,
				"testing bypass reaches both local seat decks with no modal")
			var view := run._combat_view
			await _press(_card_button(view, BLOCK))
			_check(view._state.players[FIRST].block == 5 and view._state.players[FIRST].mana == 2
				and view._state.action_history.back().spell_power_percent == 100,
				"bypass preserves full strength in the local short run")
		else:
			await _press(run.choices.get_child(0) as Button)
			var view := run._combat_view
			var copy := _copy(view._state, SOLO, STRIKE)
			_check(not view.has_node("SpellDrawingPanel") and not view._state.requires_rune(copy),
				"ordinary launch stays on instant casting")
			var target = view._state.enemies[0]
			var hp: int = target.hp
			await _select_attack(view, STRIKE, target.id)
			_check(target.hp == hp - 6 and view._state.players[SOLO].mana == 2,
				"an unopted short-run attack resolves at its original power")
		unload_current_scene()
		await _settle()
	_check(BOOSTER not in ROUTE.starting_deck and ROUTE.starting_deck.size() == 11,
		"launching either pilot leaves the shared route resource untouched")


func _test_standalone_catalogue_launch() -> void:
	change_scene_to_packed(MAIN)
	await scene_changed
	var menu := current_scene
	(menu.get_node("%SpellDrawing") as CheckBox).button_pressed = true
	(menu.get_node("%CardExpansion") as CheckBox).button_pressed = true
	(menu.get_node("%StartLocalCoopButton") as Button).pressed.emit()
	await scene_changed
	var view := current_scene as CombatView
	var catalogue := BattleMagePool.catalogue()
	_check(view != null and view.encounter.test_deck == catalogue + [BOOSTER],
		"the standalone expansion option makes the entire catalogue available with drawing enabled")
	for mage in [FIRST, SECOND]:
		var player := view._state.players[mage]
		for index in catalogue.size():
			_check(view._state.requires_rune(player.first_copy_id + index),
				"%s uses a rune in %s's standalone catalogue deck" % [catalogue[index].display_name, mage])
		_check(not view._state.requires_rune(player.first_copy_id + catalogue.size()),
			"the practice Booster remains instant for %s" % mage)
	unload_current_scene()
	await _settle()


func _test_seeded_draws() -> void:
	var drawing := RunState.new(ROUTE, SETTINGS)
	var plain := RunState.new(ROUTE)
	_check(drawing.choose_opening(PortalRoute.START) and plain.choose_opening(PortalRoute.START),
		"comparison opens the same seed and route with and without drawing")
	var drawn := drawing.active_combat
	var normal := plain.active_combat
	var player := drawn.players[SOLO]
	var control_player := normal.players[SOLO]
	_check(drawn.shuffle_seed == normal.shuffle_seed and player.hand == control_player.hand
		and player.draw_pile == control_player.draw_pile, "drawing configuration does not consume opening shuffle RNG")
	var copy := _copy(drawn, SOLO, STRIKE)
	var pending := drawn.begin_spell_cast(SOLO, copy, drawn.enemies[0].id)
	_check(not pending.is_empty() and drawn.start_spell_cast_clock(SOLO, 0) > 0 and drawn.cancel_spell_cast(SOLO),
		"opening and canceling a cast leaves the turn available")
	for round in range(2):
		var expected_min_hp := 10
		_check(drawn.end_turn(SOLO) and normal.end_turn(SOLO) and drawn.round_number == normal.round_number
			and player.hp == control_player.hp and player.hp >= expected_min_hp and player.hand == control_player.hand
			and player.draw_pile == control_player.draw_pile and player.discard_pile == control_player.discard_pile,
			"draw, discard, reshuffle and enemy phase match after canceled drawing in round %d" % round)


func _test_solo_portal_run() -> void:
	var fixture := _fixture(true)
	var run := await _open_run(fixture)
	await _press(_choice(run, "The Tower"))
	await _press(run.choices.get_child(0) as Button)
	var opening := run._combat_view
	var state := opening._state
	var first := state.enemies[0]
	var second := state.enemies[1]
	first.hp = 1
	second.hp = 10
	opening._render()
	_check(opening.get_node_or_null("SpellDrawingPanel") != null and state.players[SOLO].arcana_id == MajorArcana.TOWER,
		"opening encounter is configured before play and carries the selected Arcana")
	await _press(_card_button(opening, STRIKE))
	_check(not _panel(opening).visible and opening._pending_card_copy >= 0,
		"selecting a rune attack waits for an enemy target")
	await _press(opening.get_node("%CancelTargetButton"))
	_check(opening._pending_card_copy < 0 and state.action_history.is_empty(),
		"canceling target selection spends nothing and opens no cast")
	await _select_attack(opening, STRIKE, second.id)
	_check(_panel(opening).visible and not state.can_end_turn(SOLO)
		and state.players[SOLO].mana == 3, "the drawing modal owns the selected target and holds the turn")
	second.hp = 0
	await _submit_guide(opening)
	_check(first.hp == 1 and state.players[SOLO].mana == 3 and state.action_history.is_empty(),
		"invalidated target is rechecked before payment or Arcana activation")
	second.hp = 10
	opening._render()
	await _select_attack(opening, STRIKE, second.id)
	await _press(_panel(opening).get_node("%CancelButton"))
	_check(state.submit_spell_cast(SOLO, STRIKE.rune_template.strokes, Time.get_ticks_msec()) == CombatState.CastResult.NO_CAST,
		"submission from the canceled drawing cannot resolve later in the same encounter")
	await _select_attack(opening, STRIKE, second.id)
	await _submit_guide(opening)
	_check(second.hp == 0 and first.hp == 1 and state.players[SOLO].mana == 2 and state.players[SOLO].burning == 3
		and state.players[SOLO].arcana_used and state.action_history.back().spell_power_percent == 110,
		"exact targeted casting combines with Tower, spends one Mana, and hits only the selected Slime")
	var guard_copy := _copy(state, SOLO, GUARD)
	await _press(_card_button(opening, GUARD))
	_check(_panel(opening).visible and state.players[SOLO].mana == 2,
		"the new hybrid rune holds Arcane Guard until drawing resolves")
	await _submit_guide(opening)
	_check(state.players[SOLO].block == 8 and state.players[SOLO].mana == 1
		and state.players[SOLO].discard_pile.count(guard_copy) == 1 and state.players[SOLO].hand.size() == 4,
		"Arcane Guard scales only Block and draws exactly one card in the solo run")
	await _select_attack(opening, STRIKE, first.id)
	await _submit_guide(opening)
	_check(state.phase == CombatState.Phase.VICTORY and state.players[SOLO].mana == 0,
		"drawn attacks can win the opening combat")
	_check(run._run.stage == RunState.Stage.REWARD and run._combat_view == opening
		and _reward(opening).visible and not _panel(opening).visible,
		"victory automatically opens rewards over the same battlefield after closing the cast")
	var opening_counts: Dictionary = run._casting_pacing.encounters[1]
	_check(opening_counts.prompts == 5 and opening_counts.successful == 3 and opening_counts.excellent == 3
		and opening_counts.canceled == 1 and opening_counts.drawing_ms >= 0 and opening_counts.casts_by_seat[1] == 3,
		"opening metrics count resolved, invalid and canceled prompts once")
	_check(run._run.reward_options() == fixture.reward_offers(RunData.BATTLE_MAGE, 1, 0)
		and state.submit_spell_cast(SOLO, STRIKE.rune_template.strokes, Time.get_ticks_msec()) == CombatState.CastResult.NO_CAST,
		"expanded reward offers stay seeded and the old combat cannot resolve stale ink")
	await _press(_reward_choice(opening, "Astral Salvo"))
	_check(run._run.stage == RunState.Stage.PORTAL and run._run.deck_cards() == fixture.starting_deck + [ASTRA]
		and run._combat_view == opening and not _reward(opening).visible
		and _reward(opening).get_node("%RewardChoices").get_child_count() == 0,
		"the reward adds Salvo and clears private controls before showing portals on the same battlefield")
	var route := PortalRoute.new(fixture.run_seed)
	var seed_rng := RandomNumberGenerator.new()
	seed_rng.seed = fixture.run_seed
	seed_rng.randi()
	var first_source := PortalRoute.START
	var cast_drafted_salvo := false
	for index in range(2, 5):
		var portal: Dictionary = run._run.portal_options()[0]
		var expected := route.destination(first_source, StringName(portal.id))
		var carried_hp := run._run.current_hp
		await _press(run._combat_view.get_node("%PortalChoices").get_child(0) as Button)
		var view := run._combat_view
		var active := view._state
		_check(run._run.encounter_id == index and run._run.active_encounter.enemy_id == expected.enemy_id
			and active.shuffle_seed == seed_rng.randi() and active.players[SOLO].hp == carried_hp
			and active.players[SOLO].arcana_id == MajorArcana.TOWER and not active.players[SOLO].arcana_used
			and not _panel(view).visible, "portal encounter %d preserves seeded destination, HP, Arcana and a fresh modal" % index)
		_check(active.card_data(fixture.starting_deck.size()) == ASTRA
			and active.requires_rune(fixture.starting_deck.size()),
			"the drafted Salvo remains a rune card in encounter %d" % index)
		if not cast_drafted_salvo and _copy(active, SOLO, ASTRA) >= 0:
			var target = active.enemies[-1]
			target.hp = 35
			await _select_attack(view, ASTRA, target.id)
			await _submit_guide(view)
			cast_drafted_salvo = target.hp == 14 and active.players[SOLO].mana == 1
		await _win_remaining(view)
		_check(active.phase == CombatState.Phase.VICTORY, "drawn cards clear portal encounter %d" % index)
		first_source = expected.enemy_id
		if index < 4:
			await _press(_reward(view).get_node("%SkipReward") as Button)
	_check(cast_drafted_salvo, "an acquired Salvo draws and resolves both scaled hits once in a later encounter")
	_check(run._run.stage == RunState.Stage.VICTORY and run.heading.text == "Run Victory"
		and run._combat_view == null and run._run.active_combat == null,
		"the solo portal route reaches its clean terminal victory")
	var sum_of_prompts := 0
	for counts: Dictionary in run._casting_pacing.encounters.values():
		sum_of_prompts += counts.prompts
	var totals: Dictionary = run._casting_pacing.totals
	_check(run._casting_pacing.encounters.size() == 4 and totals.prompts == sum_of_prompts
		and totals.successful == totals.prompts - 2 and totals.casts_by_seat[1] == totals.successful
		and "Encounter 4" in run.heading.tooltip_text, "the victory panel retains consistent per-run and per-encounter counters")
	print("M19_PACING_FIXTURE ", JSON.stringify({"solo_portal_victory": totals}))
	run.queue_free()
	await _settle()


func _test_local_run() -> void:
	var fixture := _fixture(false)
	var run := await _open_run(fixture, true)
	var view := run._combat_view
	var state := view._state
	var host := state.players[FIRST]
	var ally := state.players[SECOND]
	await _press(_card_button(view, BOOSTER))
	_check(host.spell_booster_primed and not ally.spell_booster_primed and host.mana == 2,
		"an instant Booster primes only its local owner")
	var selector := view.get_node("%PlayerSelector")
	await _select_attack(view, STRIKE, state.enemies[1].id)
	await _press(selector.get_child(1) as Button)
	_check(_panel(view).visible and view._selected_player_id == FIRST
		and state.submit_spell_cast(SECOND, STRIKE.rune_template.strokes, Time.get_ticks_msec()) == CombatState.CastResult.NO_CAST,
		"the active casting seat cannot be switched or resolve through the other Mage")
	await _press(_panel(view).get_node("%CancelButton"))
	_check(host.spell_booster_primed and host.mana == 2, "cancel preserves the caster's charge and Mana")
	await _press(selector.get_child(1) as Button)
	await _press(_card_button(view, BLOCK))
	await _submit_guide(view)
	_check(ally.block == 6 and ally.mana == 2 and host.spell_booster_primed and host.block == 0,
		"an exact rune for Mage 2 cannot spend Mage 1's charge")
	await _press(view.end_turn_button)
	_check(state.round_number == 1 and ally.ended_turn and not host.ended_turn and state.can_undo_ready(SECOND),
		"Ready remains reversible after casting")
	await _press(view.end_turn_button)
	_check(not ally.ended_turn and state.round_number == 1, "Undo Ready resumes the shared player phase")
	await _press(selector.get_child(0) as Button)
	state.enemies[0].hp = 1
	state.enemies[1].hp = 1
	await _select_attack(view, STRIKE, state.enemies[1].id)
	await _submit_guide(view)
	_check(host.mana == 1 and not host.spell_booster_primed and state.action_history.back().spell_power_percent == 130,
		"the owner's eligible cast spends the charge once")
	await _select_attack(view, STRIKE, state.enemies[0].id)
	await _submit_guide(view)
	var overlay := _reward(view)
	var reveal := overlay.get_node("%RevealReward") as Button
	var deck_list := overlay.get_node("%DeckList") as Control
	_check(run._local_run.stage == CoopRunState.REWARD and run._combat_view == view
		and not deck_list.is_visible_in_tree() and reveal.visible and FIRST in reveal.text,
		"the local victory starts with a private reward handoff")
	var totals: Dictionary = run._casting_pacing.totals
	_check(totals.prompts == 4 and totals.successful == 3 and totals.canceled == 1
		and totals.casts_by_seat[1] == 2 and totals.casts_by_seat[2] == 1,
		"pacing counts each local Mage's completed casts separately")
	await _press(reveal)
	(overlay.get_node("%DeckToggle") as Button).button_pressed = true
	await _settle()
	_check(deck_list.is_visible_in_tree() and _reward_choice(view, "Astral Salvo") != null,
		"Mage 1 alone sees the seeded expanded reward and personal deck")
	await _press(_reward_choice(view, "Astral Salvo"))
	_check(not deck_list.is_visible_in_tree() and reveal.visible and SECOND in reveal.text
		and overlay.get_node("%RewardChoices").get_child_count() == 0,
		"Mage 2's handoff hides the previous seat's deck")
	await _press(reveal)
	await _press(overlay.get_node("%SkipReward") as Button)
	var next := run._combat_view
	var next_state := next._state
	_check(run._local_run.encounter_id == 2 and ASTRA in run._local_run.deck_cards(FIRST)
		and ASTRA not in run._local_run.deck_cards(SECOND) and next_state.requires_rune(fixture.starting_deck.size())
		and not _panel(next).visible, "the next local encounter keeps the private deck carryover and starts a fresh modal")
	var next_selector := next.get_node("%PlayerSelector")
	if _copy(next_state, FIRST, ASTRA) < 0:
		await _press(next.end_turn_button)
		await _press(next_selector.get_child(1) as Button)
		await _press(next.end_turn_button)
		await _press(next_selector.get_child(0) as Button)
	await _select_attack(next, ASTRA, next_state.enemies[1].id)
	await _submit_guide(next)
	_check(next_state.players[FIRST].mana == 1 and next_state.players[SECOND].mana == 3
		and next_state.action_history.back().spell_power_percent == 110
		and next_state.enemies[0].hp == 29 and next_state.enemies[1].hp + next_state.enemies[1].block < 35,
		"the awarded spell targets a single enemy in the next encounter and charges only Mage 1")
	next_state.players[FIRST].hp = 1
	next_state.players[SECOND].hp = 1
	# Goblin and Treant open with Strength and Block, then attack.
	for round in range(2):
		if next_state.phase == CombatState.Phase.DEFEAT:
			break
		await _press(next_selector.get_child(0) as Button)
		await _press(next.end_turn_button)
		await _press(next_selector.get_child(1) as Button)
		await _press(next.end_turn_button)
	_check(next_state.phase == CombatState.Phase.DEFEAT, "the shared enemy phase can defeat the opted-in party")
	await _settle()
	_check(run._local_run.stage == CoopRunState.DEFEAT and run.heading.text == "Run Defeat"
		and run._combat_view == null and next_state.submit_spell_cast(FIRST, STRIKE.rune_template.strokes,
			Time.get_ticks_msec()) == CombatState.CastResult.NO_CAST,
		"local defeat closes drawing and rejects stale ink")
	print("M19_PACING_FIXTURE ", JSON.stringify({"local_linear_defeat": totals}))
	run.queue_free()
	await _settle()


func _test_local_victory() -> void:
	var fixture: RunData = ROUTE.duplicate()
	fixture.starting_deck = [TWIN, STRIKE, GUARD, BLOCK, BOOSTER]
	var run := await _open_run(fixture, true)
	for encounter_id in range(1, fixture.encounter_count() + 1):
		var view := run._combat_view
		var state := view._state
		var selector := view.get_node("%PlayerSelector")
		for slot in state.enemies.size():
			var seat := slot % 2
			var mage := FIRST if seat == 0 else SECOND
			var target := state.enemies[slot]
			target.hp = 1
			view._render()
			await _press(selector.get_child(seat) as Button)
			await _select_attack(view, TWIN, target.id)
			await _submit_guide(view)
			_check(target.hp == 0 and state.players[mage].mana == 2
				and state.action_history.back().spell_power_percent == 110,
				"the newly assigned multi-hit rune resolves for its own seat in fight %d" % encounter_id)
		_check(state.phase == CombatState.Phase.VICTORY, "drawn attacks clear local fight %d" % encounter_id)
		if encounter_id < fixture.encounter_count():
			for mage in [FIRST, SECOND]:
				var reveal := _reward(view).get_node("%RevealReward") as Button
				_check(mage in reveal.text, "the correct Mage privately receives the reward handoff")
				await _press(reveal)
				await _press(_reward(view).get_node("%SkipReward") as Button)
	_check(run._local_run.stage == CoopRunState.VICTORY and run.heading.text == "Run Victory"
		and run._combat_view == null and run._casting_pacing.encounters.size() == 3
		and run._casting_pacing.totals.casts_by_seat == {1: 3, 2: 2},
		"both local seats cast through the full route and victory closes the drawing view")
	run.queue_free()
	await _settle()


func _test_abandoned_cast() -> void:
	var fixture := _fixture(false)
	var salvo: CardData = ASTRA.duplicate()
	var rune: RuneTemplate = ASTRA.rune_template.duplicate()
	rune.cast_time_ms = 500
	salvo.rune_template = rune
	fixture.starting_deck[0] = salvo
	var run := await _open_run(fixture)
	await _press(run.choices.get_child(0) as Button)
	var combat := run._combat_view
	var state := combat._state
	var pacing = run._casting_pacing
	await _select_attack(combat, salvo, state.enemies[0].id)
	var panel := _panel(combat)
	var canvas := panel.get_node("%RuneCanvas") as RuneCanvas
	_draw_stroke(canvas, canvas._guide[0], false)
	var watchdog := Time.get_ticks_msec() + 3000
	while panel.visible and Time.get_ticks_msec() < watchdog:
		await process_frame
	_check(not panel.visible and state.enemies[0].hp == 8 and state.players[SOLO].mana == 1
		and pacing.totals.prompts == 1 and pacing.totals.successful == 1 and pacing.totals.faint == 1
		and pacing.totals.expired == 1 and pacing.totals.drawing_ms > 0,
		"a held outline auto-resolves faint at expiry and counts as both expired and successful")
	_mouse_button(canvas.get_global_rect().get_center(), false)
	await _select_attack(combat, STRIKE, state.enemies[0].id)
	_check(_panel(combat).visible, "the abandonment fixture opens a pending cast")
	run.queue_free()
	await _settle()
	_check(state.submit_spell_cast(SOLO, STRIKE.rune_template.strokes, Time.get_ticks_msec()) == CombatState.CastResult.NO_CAST
		and state.players[SOLO].mana == 1 and state.action_history.size() == 1 and pacing.totals.canceled == 1,
		"closing the run discards the pending drawing and cannot pay or resolve it later")


func _fixture(portals: bool) -> RunData:
	var data := BattleMagePool.with_expanded_rewards(ROUTE)
	data.portal_enabled = portals
	data.major_arcana_enabled = portals
	# Small fixture deck makes a drawn rune available whenever an encounter starts.
	data.starting_deck = [STRIKE, STRIKE, GUARD, BLOCK, BOOSTER]
	# Use deterministic seeds that actually offer Salvo to the first seat.
	for seed in range(104775, 104875):
		data.run_seed = seed
		if ASTRA in data.reward_offers(RunData.BATTLE_MAGE, 1, 0) \
				and (not portals or MajorArcana.TOWER in MajorArcana.offers(seed, 0, RunData.BATTLE_MAGE)):
			return data
	_check(false, "the test seed range must offer the expected reward and Arcana")
	return data


func _open_run(data: RunData, local := false) -> PrototypeRunView:
	var run := RUN.instantiate() as PrototypeRunView
	run.run_data = data
	run.local_coop = local
	run.spell_drawing = SETTINGS
	_viewport.add_child(run)
	await _settle()
	return run


func _win_remaining(view: CombatView) -> void:
	var state := view._state
	for enemy in state.enemies:
		if enemy.is_alive():
			enemy.hp = 1
	for attack_slot in range(12):
		if state.phase != CombatState.Phase.PLAYER:
			return
		var target: StringName
		for enemy in state.enemies:
			if enemy.is_alive():
				target = enemy.id
				break
		var copy := _copy(state, SOLO, STRIKE)
		if copy < 0 or not state.can_play_card(SOLO, copy, target):
			await _press(view.end_turn_button)
		else:
			await _select_attack(view, STRIKE, target)
			await _submit_guide(view)


func _select_attack(view: CombatView, card: CardData, target: StringName) -> void:
	await _press(_card_button(view, card))
	if view._pending_card_copy >= 0:
		await _press(view._enemy_buttons.get(target))


func _submit_guide(view: CombatView) -> void:
	var panel := _panel(view)
	var canvas := panel.get_node("%RuneCanvas") as RuneCanvas
	if not _check(panel.visible and canvas._drawing_enabled, "a run cast waits for the live drawing canvas"):
		return
	for stroke in canvas._guide:
		_draw_stroke(canvas, stroke)
	await _press(panel.get_node("%SubmitButton"))


func _draw_stroke(canvas: RuneCanvas, stroke: PackedVector2Array, release := true) -> void:
	var points := canvas._local_points(stroke)
	var transform := canvas.get_global_transform_with_canvas()
	_mouse_button(transform * points[0], true)
	for index in range(1, points.size()):
		var event := InputEventMouseMotion.new()
		event.button_mask = MOUSE_BUTTON_MASK_LEFT
		event.position = transform * points[index]
		event.global_position = event.position
		_viewport.push_input(event, true)
	if release:
		_mouse_button(transform * points[-1], false)


func _panel(view: CombatView) -> Control:
	return view.get_node("SpellDrawingPanel") as Control


func _copy(fight: CombatState, player: StringName, card: CardData) -> int:
	for id: int in fight.players[player].hand:
		if fight.card_data(id) == card:
			return id
	return -1


func _card_button(view: CombatView, card: CardData) -> Button:
	for button: Button in view.hand_cards.get_children():
		if button.text.begins_with(card.display_name + "\n"):
			return button
	return null


func _choice(run: PrototypeRunView, title: String) -> Button:
	for choice: Button in run.choices.get_children():
		if choice.text.begins_with(title):
			return choice
	return null


func _reward(view: CombatView) -> Control:
	return view.get("reward_overlay") as Control


func _reward_choice(view: CombatView, title: String) -> Button:
	for choice: Button in _reward(view).get_node("%RewardChoices").get_children():
		if choice.text.begins_with(title):
			return choice
	return null


func _press(button: Button) -> void:
	if not _check(button != null and not button.disabled, "the intended action is available"):
		return
	button.pressed.emit()
	await _settle()


func _mouse_button(position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = position
	event.global_position = position
	event.pressed = pressed
	_viewport.push_input(event, true)


func _settle() -> void:
	for frame in range(3):
		await process_frame


func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
