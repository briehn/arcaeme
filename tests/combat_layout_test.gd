extends SceneTree

const CombatState = preload("res://scripts/combat/combat_state.gd")
const MajorArcana = preload("res://scripts/run/major_arcana.gd")
const BattleMagePool = preload("res://scripts/run/battle_mage_pool_playtest.gd")
const PortalRoute = preload("res://scripts/run/portal_route.gd")
const NetworkSession = preload("res://scripts/network/network_coop_session.gd")
const ViewSnapshot = preload("res://scripts/combat/combat_view_snapshot.gd")
const MAIN = preload("res://scenes/main.tscn")
const NETWORK = preload("res://scenes/network_coop.tscn")
const SOLO = preload("res://scenes/combat.tscn")
const LOCAL = preload("res://scenes/local_coop.tscn")
const STATUS = preload("res://scenes/status_playtest.tscn")
const RUN = preload("res://scenes/prototype_run.tscn")
const MULTI_ENEMY_RUN = preload("res://resources/prototype/multi_enemy_run.tres")
const ENCOUNTER = preload("res://resources/prototype/status_playtest/encounter.tres")
const MODIFIER_ENCOUNTER = preload("res://resources/prototype/modifier_playtest/encounter.tres")
const TWO_SLIMES = preload("res://resources/prototype/enemies/two_slimes.tres")
const THREE_ENEMIES = preload("res://resources/prototype/enemies/three_enemies.tres")
const REVERSAL = preload("res://resources/prototype/cards/arcane_reversal.tres")
const MIRROR_LUNGE = preload("res://resources/prototype/cards/pool_expansion/mirror_lunge.tres")
const SHATTERGUARD = preload("res://resources/prototype/cards/pool_expansion/shatterguard.tres")
const TACTICIANS_PAGE = preload("res://resources/prototype/cards/pool_expansion/tacticians_page.tres")
const NAMES: Array[StringName] = [&"Battle Mage 1", &"Battle Mage 2", &"Battle Mage 3", &"Battle Mage 4"]
const VIEWPORT_SIZES := [Vector2i(960, 540), Vector2i(1024, 576), Vector2i(1280, 720), Vector2i(1920, 1080)]

var _viewport: SubViewport
var _size: Vector2i
var _checks := 0
var _failures := 0
var _end_requests := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for viewport_size in VIEWPORT_SIZES:
		_size = viewport_size
		var initial_checks := _checks
		var initial_failures := _failures
		_viewport = SubViewport.new()
		_viewport.size = _size
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(_viewport)
		await _test_menu()
		await _test_combat(SOLO, "solo", false)
		await _test_combat(LOCAL, "local co-op", false)
		await _test_combat(STATUS, "solo status", true)
		await _test_two_slimes(SOLO, false)
		await _test_two_slimes(LOCAL, true)
		await _test_solo_run()
		await _test_multi_enemy_run(false)
		await _test_multi_enemy_run(true)
		await _test_expanded_rewards(false)
		await _test_expanded_rewards(true)
		await _test_portal_run(false)
		await _test_portal_run(true)
		await _test_arcana_run(false)
		await _test_arcana_run(true)
		await _test_network()
		_viewport.queue_free()
		await process_frame
		print("%dx%d layout: %d checks, %d failures." %
			[_size.x, _size.y, _checks - initial_checks, _failures - initial_failures])
	print("Combat layout: %d checks, %d failures." % [_checks, _failures])
	quit(1 if _failures else 0)


func _test_menu() -> void:
	var menu := await _open(MAIN)
	var logo := _control(menu, "%LogoDisplay") as TextureRect
	_check_control(logo, "main menu")
	_check(logo.texture != null and logo.texture.get_size() == Vector2(3000, 1200)
		and logo.get_global_rect().end.x < _size.x * 0.55, "source logo fits the left side")
	var primary := _control(menu, "%PrimaryNavigation")
	for button in primary.get_children():
		_check_control(button, "main menu")
	_check(logo.get_global_rect().end.y < primary.get_global_rect().position.y, "navigation starts below the logo")
	var start := _control(menu, "%StartCombatButton") as Button
	_check(start.get_theme_stylebox("normal") != start.get_theme_stylebox("hover")
		and start.get_theme_stylebox("normal") != start.get_theme_stylebox("pressed")
		and start.get_theme_stylebox("focus") != null, "main action has distinct feedback states")
	var open_tools := _control(menu, "%OpenPrototypeTools")
	_click(open_tools)
	await _settle()
	var back := _control(menu, "%BackFromTools")
	var tools := _control(menu, "%PrototypeNavigation")
	_check(not primary.visible and tools.visible and back.has_focus(), "prototype tools open with a focused return action")
	var portal := _control(menu, "%PortalPrototype") as CheckBox
	_check(await _reach(portal) and not portal.button_pressed, "main menu portal routes are reachable and opt-in")
	var battle_mage_pool := _control(menu, "%BattleMagePool") as CheckBox
	_check(await _reach(battle_mage_pool) and not battle_mage_pool.button_pressed,
		"main menu expanded Battle Mage rewards are reachable and opt-in")
	_check_button_text(battle_mage_pool, "main menu expanded Battle Mage toggle")
	for path in ["%StartRunButton", "%StartEnemyVarietyRunButton", "%StartLocalCoopButton",
			"%StartStatusPlaytestButton", "%StartModifierPlaytestButton", "%CardExpansion",
			"%EnemyPlaytest", "%StartEnemyPlaytestButton"]:
		var control := _control(menu, path)
		_check(await _reach(control), "%s is reachable in prototype tools" % control.name)
	var picker := _control(menu, "%EnemyPlaytest") as OptionButton
	for index in picker.item_count:
		if picker.get_item_text(index).begins_with("Two Slimes"):
			picker.select(index)
			picker.item_selected.emit(index)
			break
	await _settle()
	var local_fixture := menu.get_node_or_null("%StartEnemyLocalCoopButton") as Button
	_check(local_fixture != null and await _reach(local_fixture), "tactical local co-op appears and is reachable")
	_check_control(back, "prototype tools after scrolling")
	_click(back)
	await _settle()
	_check(primary.visible and not tools.visible and open_tools.has_focus() and _fully_visible(open_tools),
		"return restores focus and the primary navigation position")
	await _close(menu)


func _test_combat(scene: PackedScene, context: String, status_mode: bool) -> void:
	var combat := await _open(scene)
	await _check_combat(combat, context)
	if scene == SOLO:
		var log := _control(combat, "%CombatLog")
		var log_toggle := _control(combat, "%CombatLogToggle") as Button
		_check(not log.visible and await _reach(log_toggle), "combat log is collapsed and reachable")
		await _act_on(log_toggle, "open combat log")
		_check(log.visible and await _reach(log), "expanded combat log is visible")
		await _act_on(log_toggle, "close combat log")
		_check(not log.visible, "collapsing the log returns its space to the hand")
	var end := _control(combat, "%EndTurnButton") as Button
	var initial_turn: String = (_control(combat, "%TurnLabel") as Label).text
	var initial_hp := (_control(combat, "%PlayerLabel") as Label).text
	if status_mode:
		var poison := _card(combat, "Test Toxic Spark")
		if poison != null and await _reach(poison):
			_click(poison)
			await _settle()
		_check("Poison 4" in (_control(combat, "%EnemyLabel") as Label).text, "solo status card can be clicked")
	if await _reach(end):
		_click(end)
		await _settle()
		var turn: Label = _control(combat, "%TurnLabel")
		var players: Label = _control(combat, "%PlayerLabel")
		_check(turn.text != initial_turn or players.text != initial_hp, "%s End Turn handles viewport input" % context)
	if status_mode:
		_check("Poison 1" in (_control(combat, "%PlayerLabel") as Label).text and
			"Burning 3" in (_control(combat, "%PlayerLabel") as Label).text, "solo status effects remain readable after End Turn")
	await _close(combat)


func _test_solo_run() -> void:
	var run := await _open(RUN)
	var choices := _control(run, "%Choices")
	for choice in choices.get_children():
		_check_control(choice, "solo run route")
	_check_control(_control(run, "%RunBackButton"), "solo run route")
	if await _reach(choices.get_child(0) as Control):
		_click(choices.get_child(0) as Control)
		await _settle()
		var combat := run.get_node("Combat") as Control
		await _check_combat(combat, "solo run fight")
	await _close(run)


func _test_multi_enemy_run(local_coop: bool) -> void:
	var run := RUN.instantiate() as Control
	run.run_data = MULTI_ENEMY_RUN
	run.local_coop = local_coop
	_viewport.add_child(run)
	await _settle()
	var choices := _control(run, "%Choices")
	if not local_coop:
		await _act_on(choices.get_child(0) as Button, "solo multi-enemy opening")
	await _check_run_encounter(run, "Encounter 1 of 3", "Two Slimes")
	var battlefield := run.get_node("Combat") as Control
	await _finish_displayed_fight(run)
	var heading := _control(run, "%Heading") as Label
	var reward := _reward_overlay(battlefield)
	var offers := _control(reward, "%RewardChoices")
	var skip := _control(reward, "%SkipReward") as Button
	var status := _control(reward, "%RewardStatus") as Label
	_check(run.get_node("Combat") == battlefield and reward.is_visible_in_tree(),
		"victory automatically opens rewards above the same battlefield")
	if local_coop:
		var reveal := _control(reward, "%RevealReward") as Button
		var deck_toggle := _control(reward, "%DeckToggle") as Button
		var deck_list := _control(reward, "%DeckList") as Label
		_check("0/2" in status.text and offers.get_child_count() == 0 and not deck_toggle.visible
			and "Battle Mage 1" in reveal.text,
			"local handoff waits for Mage 1 to reveal their reward")
		await _act_on(reveal, "Mage 1 reward reveal")
		await _act_on(deck_toggle, "Mage 1 private run deck")
		_check(deck_list.visible and not deck_list.text.is_empty() and offers.get_child_count() > 1,
			"Mage 1's own deck and choices are visible after reveal")
		await _act_on(offers.get_child(0) as Button, "Mage 1 reward choice")
		_check("1/2" in status.text and not deck_toggle.visible and deck_list.text.is_empty()
			and offers.get_child_count() == 0 and "Battle Mage 2" in reveal.text,
			"local reward pass hides Mage 1's choice and deck before Mage 2")
		await _act_on(reveal, "Mage 2 reward reveal")
		await _act_on(deck_toggle, "Mage 2 private run deck")
		_check(_private_deck_size(deck_list.text) == MULTI_ENEMY_RUN.starting_deck.size(),
			"Mage 2 sees their own starting deck before making a choice")
		await _act_on(skip, "Mage 2 reward skip")
	else:
		_check("Card reward" in (_control(reward, "%RewardTitle") as Label).text
			and "Goblin + Treant" in status.text,
			"solo reward panel names the next encounter")
		await _act_on(offers.get_child(0) as Button, "solo multi-enemy reward choice")
		_check("Encounter 2 of 3" in heading.text, "solo post-reward screen previews encounter two")
		await _act_on(choices.get_child(0) as Button, "solo second encounter")
	await _check_run_encounter(run, "Encounter 2 of 3", "Goblin + Treant")
	await _finish_displayed_fight(run)
	reward = _reward_overlay(run.get_node("Combat") as Control)
	skip = _control(reward, "%SkipReward") as Button
	if local_coop:
		var reveal := _control(reward, "%RevealReward") as Button
		_check("0/2" in (_control(reward, "%RewardStatus") as Label).text and "Battle Mage 1" in reveal.text,
			"local reward decisions reopen for both Mages after the second encounter")
		for seat in 2:
			await _act_on(reveal, "second reward reveal for Mage %d" % (seat + 1))
			await _act_on(skip, "second reward skip for Mage %d" % (seat + 1))
	else:
		await _act_on(skip, "solo second reward skip")
		await _act_on(choices.get_child(0) as Button, "solo Citadel Warden encounter")
	await _check_run_encounter(run, "Encounter 3 of 3", "Boss: Citadel Warden")
	await _finish_displayed_fight(run)
	_check(heading.text == "Run Victory", "the final encounter reaches the run victory panel")
	_check_control(_control(run, "%RunBackButton"), "multi-enemy run victory")
	await _close(run)


func _test_expanded_rewards(local_coop: bool) -> void:
	var run := RUN.instantiate() as Control
	run.run_data = BattleMagePool.with_expanded_rewards(MULTI_ENEMY_RUN)
	run.local_coop = local_coop
	_viewport.add_child(run)
	await _settle()
	var choices := _control(run, "%Choices")
	if not local_coop:
		await _act_on(choices.get_child(0) as Button, "expanded reward run opening")
	await _finish_displayed_fight(run)
	var reward := _reward_overlay(run.get_node("Combat") as Control)
	var reveal := _control(reward, "%RevealReward") as Button
	var skip := _control(reward, "%SkipReward") as Button
	var offers := _control(reward, "%RewardChoices")
	if local_coop:
		await _act_on(reveal, "expanded reward reveal")
	_check(offers.get_child_count() == 3 and await _reach(skip), "expanded run displays three choices and Skip")
	var accents: Array[Color] = []
	for button: Button in offers.get_children():
		_check(await _reach(button), "expanded reward is reachable")
		_check_button_text(button, "expanded reward")
		var frame := button.get_theme_stylebox("normal") as StyleBoxFlat
		if frame != null and frame.border_color not in accents:
			accents.append(frame.border_color)
	_check(accents.size() == 3, "the three reward cards have distinct visual accents")
	await _act_on(offers.get_child(0) as Button, "take the first expanded reward")
	if local_coop:
		_check(offers.get_child_count() == 0 and reveal.visible and "Battle Mage 2" in reveal.text,
			"local handoff keeps the prior seat's expanded options private")
		await _act_on(reveal, "expand the second seat's reward")
		await _act_on(skip, "skip the second seat's expanded reward")
	else:
		await _act_on(choices.get_child(0) as Button, "start the next fight with the expanded reward")
	await _check_run_encounter(run, "Encounter 2 of 3", "Goblin + Treant")
	await _close(run)


func _check_run_encounter(run: Control, progress: String, encounter: String) -> void:
	var combat := run.get_node("Combat") as Control
	var title := _control(combat, "%TitleLabel") as Label
	_check(progress in title.text and encounter in title.text, "run combat shows " + progress + " and " + encounter)
	_check(await _reach(title), "multi-enemy run combat title is fully readable")
	_check_control(_control(combat, "%EndTurnButton"), "multi-enemy run combat")


func _test_portal_run(local_coop: bool) -> void:
	var run := RUN.instantiate() as Control
	run.run_data = MULTI_ENEMY_RUN.duplicate()
	run.run_data.portal_enabled = true
	run.local_coop = local_coop
	_viewport.add_child(run)
	await _settle()
	var choices := _control(run, "%Choices")
	if not local_coop:
		await _act_on(choices.get_child(0) as Button, "solo portal opening")
	await _check_run_encounter(run, "Encounter 1 of 4", "Two Slimes")
	var battlefield := run.get_node("Combat") as Control
	await _finish_displayed_fight(run)
	var reward := _reward_overlay(battlefield)
	var skip := _control(reward, "%SkipReward") as Button
	var portals := _control(battlefield, "%PortalChoices")
	_check(reward.is_visible_in_tree() and not portals.is_visible_in_tree(),
		"private reward opens automatically before portals")
	if not local_coop:
		await _capture_intermission("reward")
	if local_coop:
		var reveal := _control(reward, "%RevealReward") as Button
		for seat in 2:
			await _act_on(reveal, "portal reward reveal for Mage %d" % (seat + 1))
			await _act_on(skip, "portal reward skip for Mage %d" % (seat + 1))
	else:
		await _act_on(skip, "solo portal reward skip")
	var portal_status := _control(battlefield, "%PortalStatus") as Label
	_check(run.get_node("Combat") == battlefield and portals.get_child_count() == 2
		and not reward.visible and _control(reward, "%RewardChoices").get_child_count() == 0
		and not _control(battlefield, "%EnemyPicker").visible,
		"physical portals replace opposition on the same battlefield after private choices clear")
	if not local_coop:
		await _capture_intermission("portals")
	for choice: Button in portals.get_children():
		_check(choice.has_meta(&"portal_id") and choice.text == "Normal Encounter\nNext portals: Normal Encounter / Normal Encounter"
			and choice.tooltip_text.is_empty()
			and await _reach(choice), "portal choice shows a readable one-step branch")
		_check_button_text(choice, "portal preview")
	var chosen_portal := portals.get_child(0) as Button
	var old_view_id := battlefield.get_instance_id()
	var route := PortalRoute.new(MULTI_ENEMY_RUN.run_seed)
	var next_name := route.destination(PortalRoute.START, StringName(chosen_portal.get_meta(&"portal_id"))).enemy_name
	await _act_on(chosen_portal, "choose a portal")
	if local_coop:
		_check("1/2" in portal_status.text and run.get_node("Combat") == battlefield,
			"local portal waits on the same battlefield for both Mages")
		await _act_on(portals.get_child(0) as Button, "choose a portal for the second Mage")
	_check(run.get_node("Combat").get_instance_id() != old_view_id, "portal vote starts a fresh combat view")
	await _check_run_encounter(run, "Encounter 2 of 4", next_name)
	await _close(run)


func _test_arcana_run(local_coop: bool) -> void:
	var run := RUN.instantiate() as Control
	run.run_data = MULTI_ENEMY_RUN.duplicate()
	run.run_data.major_arcana_enabled = true
	run.local_coop = local_coop
	_viewport.add_child(run)
	await _settle()
	var choices := _control(run, "%Choices")
	_check(not run.has_node("Combat") and (_control(run, "%Heading") as Label).text == "Choose a Major Arcana",
		"Arcana choice precedes the first fight")
	if local_coop:
		_check(choices.get_child_count() == 1 and choices.get_child(0).text == "Show Battle Mage 1 Arcana",
			"local first Mage must reveal offers")
		await _act_on(choices.get_child(0) as Button, "Mage 1 Arcana reveal")
	_check(choices.get_child_count() == 4 and choices.get_child(3).text == "Skip Arcana",
		"three Arcana choices and a skip button are present")
	for choice: Button in choices.get_children():
		_check(await _reach(choice), "Arcana choice and text are reachable")
		_check_button_text(choice, "Arcana choice")
	var selected: String = choices.get_child(0).text.get_slice("\n", 0)
	await _act_on(choices.get_child(0) as Button, "choose a Major Arcana")
	if local_coop:
		_check(not run.has_node("Combat") and choices.get_child_count() == 1
			and choices.get_child(0).text == "Show Battle Mage 2 Arcana",
			"local handoff hides offers and waits for the second Mage")
		await _act_on(choices.get_child(0) as Button, "Mage 2 Arcana reveal")
		await _act_on(choices.get_child(3) as Button, "Mage 2 Arcana skip")
	else:
		await _act_on(choices.get_child(0) as Button, "Arcana solo opening")
	var combat := run.get_node("Combat") as Control
	var arcana := _control(combat, "%ArcanaLabel") as Label
	var arcana_readable := await _reach(arcana)
	_check(selected in arcana.text and not arcana.tooltip_text.is_empty() and arcana_readable,
		"the selected Arcana and its tooltip are available in combat")
	_check_control(_control(combat, "%EndTurnButton"), "Arcana combat")
	if local_coop:
		var seat := _control(combat, "%PlayerSelector").get_child(1) as Button
		await _act_on(seat, "switch Arcana combat viewer")
		_check(not arcana.visible and arcana.text.is_empty() and arcana.tooltip_text.is_empty(),
			"the Mage who skipped sees no other Mage's Arcana UI")
	await _close(run)


func _finish_displayed_fight(run: Control) -> void:
	# Bypass damage here to check the full viewport flow at every size.
	var combat := run.get_node("Combat") as Control
	for enemy in combat._state.enemies:
		enemy.hp = 0
	combat._state.phase = CombatState.Phase.VICTORY
	combat._render()
	await _settle()


func _reward_overlay(combat: Control) -> Control:
	return combat.get("reward_overlay") as Control


func _private_deck_size(list: String) -> int:
	var count := 0
	for line in list.split("\n"):
		var copies := line.get_slice(" × ", 0)
		if copies.is_valid_int():
			count += copies.to_int()
	return count


func _capture_intermission(stage: String) -> void:
	if DisplayServer.get_name() == "headless" or _size != Vector2i(1920, 1080) \
			or "--capture-intermission" not in OS.get_cmdline_user_args():
		return
	await RenderingServer.frame_post_draw
	var path := OS.get_environment("TEMP").path_join("arcaeme-m22b-%s-1920x1080.png" % stage)
	_check(_viewport.get_texture().get_image().save_png(path) == OK, "capture 1920×1080 " + stage)


func _act_on(button: Button, context: String) -> void:
	if await _reach(button):
		_check(not button.disabled, "%s is actionable" % context)
		_click(button)
		await _settle()
	else:
		_check(false, "%s is reachable" % context)


func _test_two_slimes(scene: PackedScene, coop: bool) -> void:
	var combat := scene.instantiate() as Control
	combat.encounter = TWO_SLIMES
	_viewport.add_child(combat)
	await _settle()
	var context := "local co-op Two Slimes" if coop else "solo Two Slimes"
	if coop:
		var player_two := _control(combat, "%PlayerSelector").get_child(1) as Button
		if await _reach(player_two):
			_click(player_two)
			await _settle()
		_check((_control(combat, "%CardsLabel") as Label).text.begins_with(NAMES[1]),
			"local co-op target selection uses the second player's hand")
	var targets := _control(combat, "%EnemyTargets")
	var first := targets.get_child(0) as Button
	var second := targets.get_child(1) as Button
	var prompt := _control(combat, "%TargetLabel") as Label
	var cancel := _control(combat, "%CancelTargetButton") as Button
	var attack := _card(combat, "Basic Strike" if coop else "Arcane Reversal")
	var defense := _card(combat, "Basic Block" if coop else "Arcane Guard")
	_check(targets.get_child_count() == 2 and first.text.begins_with("Slime (1)") and
		second.text.begins_with("Slime (2)"), context + " has separate displays for duplicate Slimes")
	_check(not prompt.visible and not cancel.visible and first.disabled and second.disabled and
		attack != null and not attack.disabled and defense != null and not defense.disabled,
		context + " starts with playable cards and inactive enemy targets")
	if attack != null and await _reach(attack):
		_click(attack)
		await _settle()
	_check(prompt.visible and prompt.text.begins_with("Choose a target for") and not first.disabled and
		not second.disabled and first.has_theme_color_override("font_color") and first.has_focus()
		and _fully_visible(first), context + " clicking the card highlights and reveals living enemies")
	_check_control(cancel, context + " while targeting")
	_check_control(_control(combat, "%EndTurnButton"), context + " while targeting")
	if coop:
		var escape := InputEventKey.new()
		escape.keycode = KEY_ESCAPE
		escape.pressed = true
		_viewport.push_input(escape, true)
	else:
		_click(cancel)
	await _settle()
	_check(not prompt.visible and not cancel.visible and first.disabled and second.disabled and
		_card(combat, attack.text.get_slice("\n", 0)) == attack and "HP 22/22" in second.text,
		context + " cancelling keeps the card and enemy HP")
	if attack != null and await _reach(attack):
		_click(attack)
		await _settle()
	if await _reach(second):
		_click(second)
		await _settle()
	var expected_hp := "HP 16/22" if coop else "HP 14/22"
	_check("HP 18/18" in first.text and expected_hp in second.text and not prompt.visible,
		context + " the target click plays the card against only the chosen Slime")
	_check_control(_control(combat, "%EndTurnButton"), context + " after targeting")
	if coop:
		await _test_local_ready(combat)
	await _close(combat)


func _test_local_ready(combat: Control) -> void:
	var end := _control(combat, "%EndTurnButton") as Button
	var player_label := _control(combat, "%PlayerLabel") as Label
	var cards_label := _control(combat, "%CardsLabel") as Label
	var before := cards_label.text
	if await _reach(end):
		_click(end)
		_click(end, true)
		await _settle()
	_check(end.text == "Undo Ready · Battle Mage 2" and "Not Ready" in player_label.text.get_slice("\n", 0)
		and player_label.text.get_slice("\n", 1).ends_with("Ready") and cards_label.text == before,
		"local Ready preserves player two's hand and ignores a double-click")
	_check_control(end, "local Undo Ready")
	var defense := _card(combat, "Basic Block")
	_check(defense != null and defense.disabled, "the selected Ready player cannot play a card")
	_click(end)
	await _settle()
	_check(end.text == "End Turn · Battle Mage 2" and player_label.text.get_slice("\n", 1).ends_with("Not Ready")
		and cards_label.text == before and defense != null and not defense.disabled,
		"Undo Ready restores the local viewer's existing hand and play controls")


func _test_network() -> void:
	var scene := await _open(NETWORK)
	var session: NetworkSession = scene.get_node("Session")
	var short_run := _control(scene, "%ShortRun") as CheckBox
	var status_playtest := _control(scene, "%StatusPlaytest") as CheckBox
	var modifier_playtest := _control(scene, "%ModifierPlaytest") as CheckBox
	var party := _control(scene, "%PartySize") as OptionButton
	var port := _control(scene, "%Port") as SpinBox
	_check(port.editable and not party.disabled and party.item_count == 3, "lobby port and party size are usable")
	for path in ["%Port", "%PartySize", "%ShortRun", "%StatusPlaytest", "%ModifierPlaytest",
			"%HostButton", "%JoinButton", "%LeaveButton"]:
		_check_control(_control(scene, path), "network lobby")
	if await _reach(status_playtest):
		_click(status_playtest)
		await _settle()
	_check(session.encounter == ENCOUNTER and status_playtest.button_pressed, "status option handles viewport input")
	if await _reach(modifier_playtest):
		_click(modifier_playtest)
		await _settle()
	_check(session.encounter == MODIFIER_ENCOUNTER and modifier_playtest.button_pressed and
		not status_playtest.button_pressed, "modifier option selects a separate fixture through viewport input")
	if await _reach(short_run):
		_click(short_run)
		await _settle()
	_check(status_playtest.disabled and modifier_playtest.disabled and not modifier_playtest.button_pressed and "Short Run" in
		(_control(scene, "%HostButton") as Button).text, "short-run option updates lobby mode and status availability")
	var variety := _control(scene, "%EnemyVarietyRun") as CheckBox
	var multi_enemy := _control(scene, "%MultiEnemyRun") as CheckBox
	await _act_on(variety, "network Enemy Variety selector")
	await _act_on(multi_enemy, "network Multi-Enemy Short Run selector")
	_check(multi_enemy.button_pressed and not variety.button_pressed and session.run_data == MULTI_ENEMY_RUN
		and (_control(scene, "%HostButton") as Button).text == "Host Multi-Enemy Short Run",
		"network route selection is explicit and deselects Enemy Variety")
	var arcana_option := _control(scene, "%MajorArcana") as CheckBox
	_check(arcana_option.visible and not arcana_option.disabled and not arcana_option.button_pressed,
		"network Arcana choice is an opt-in on the multi-enemy route")
	await _act_on(arcana_option, "network Major Arcana toggle")
	var portal_option := _control(scene, "%PortalPrototype") as CheckBox
	_check(portal_option.visible and not portal_option.disabled and not portal_option.button_pressed,
		"network portals are an opt-in on the multi-enemy route")
	await _act_on(portal_option, "network Portal Routes toggle")
	var pool_option := _control(scene, "%BattleMagePool") as CheckBox
	_check(pool_option.visible and not pool_option.disabled and not pool_option.button_pressed,
		"network expanded rewards are an opt-in on the multi-enemy route")
	await _act_on(pool_option, "network expanded Battle Mage rewards")
	_check_button_text(pool_option, "network expanded Battle Mage toggle")
	await _act_on(variety, "network switch back to Enemy Variety")
	_check(not multi_enemy.button_pressed and variety.button_pressed and session.run_data != MULTI_ENEMY_RUN,
		"switching back to Enemy Variety clears the multi-enemy route")
	_check(not arcana_option.visible and not arcana_option.button_pressed, "switching routes clears Arcana opt-in")
	_check(not portal_option.visible and not portal_option.button_pressed, "switching routes clears portal opt-in")
	_check(not pool_option.visible and not pool_option.button_pressed, "switching routes clears expanded rewards opt-in")

	var combat := _control(scene, "%CombatSlot").get_node("Combat") as Control
	session.party_size = 4
	session.local_player = String(NAMES[0])
	session.connected_players = PackedStringArray(NAMES)
	session.message = "Host · Battle Mage 1 · Connected"
	session.status = NetworkSession.Status.ACTIVE
	var options: Array[Dictionary] = []
	for id in MajorArcana.offers(MULTI_ENEMY_RUN.run_seed, 0, &"battle_mage"):
		options.append(MajorArcana.view(id))
	session.snapshot = {
		"viewer": String(NAMES[0]), "run_stage": "arcana", "encounter_id": 0, "encounter_count": 3,
		"run_title": MULTI_ENEMY_RUN.title, "arcana_ready": 0, "arcana_submitted": false, "arcana_options": options,
	}
	session.changed.emit()
	await _settle()
	_check(not combat.is_visible_in_tree() and _control(scene, "%RewardChoices").get_child_count() == 3,
		"opening network Arcana offers display before combat exists")
	var skip := _control(scene, "%SkipReward") as Button
	_check(skip.text == "Skip Arcana", "the fixed button skips Arcana during selection")
	_check_control(skip, "network Arcana skip")
	for choice: Button in _control(scene, "%RewardChoices").get_children():
		_check(await _reach(choice), "network Arcana choice is reachable")
		_check_button_text(choice, "network Arcana choice")
	session.snapshot.arcana_submitted = true
	session.snapshot.arcana_options = []
	session.snapshot.arcana_ready = 1
	session.changed.emit()
	await _settle()
	_check(not skip.visible and _control(scene, "%RewardChoices").get_child_count() == 0,
		"submitted network offers stay hidden while the party finishes")
	var state := CombatState.new(ENCOUNTER, ENCOUNTER.shuffle_seed, NAMES)
	state.enemy_poison = 7
	state.enemy_burning = 3
	for player in state.players.values():
		player.poison = 1
		player.burning = 3
	var snapshot := ViewSnapshot.build(state, ENCOUNTER, NAMES[0])
	session.snapshot = snapshot
	session.changed.emit()
	await _settle()
	_check("Poison 7" in (_control(combat, "%EnemyLabel") as Label).text and
		"Burning 3" in (_control(combat, "%PlayerLabel") as Label).text, "four-player combat shows status counters")
	_check_control(_control(scene, "%ConnectionStatus"), "active network")
	_check_control(_control(scene, "%PartyRoster"), "active network")
	_check_control(_control(scene, "%LeaveButton"), "active network")
	if _size.x >= 1280 and _size.y >= 720:
		for card in _control(combat, "%HandCards").get_children():
			_check(_fully_visible(card), "four-player status opening hand shows %s without scrolling (rect %s)" %
				[card.text.get_slice("\n", 0), card.get_global_rect()])
	await _check_combat(combat, "four-player network status")
	var end := _control(combat, "%EndTurnButton") as Button
	combat.network_end_turn_requested.disconnect(session.submit_end_turn)
	combat.network_end_turn_requested.connect(func(): _end_requests += 1)
	var previous_requests := _end_requests
	if await _reach(end):
		_click(end)
		await _settle()
	_check(_end_requests == previous_requests + 1, "network End Turn emits its command from viewport input")
	await _test_long_hand(session, combat, snapshot)
	await _test_network_enemy_picker(session, combat)
	await _test_network_ready(session, combat)

	session.snapshot = _reward_snapshot(snapshot)
	session.changed.emit()
	await _settle()
	var reward := _reward_overlay(combat)
	var reward_choices := _control(reward, "%RewardChoices")
	var reward_skip := _control(reward, "%SkipReward")
	var reward_status := _control(reward, "%RewardStatus") as Label
	_check(combat.is_visible_in_tree() and reward.is_visible_in_tree() and end.disabled
		and not _control(scene, "%RewardPanel").visible,
		"network rewards dim the same battlefield with combat actions disabled")
	_check_control(_control(scene, "%RunStage"), "network reward")
	_check_control(reward_status, "network reward")
	_check_control(reward_skip, "network reward")
	for choice in reward_choices.get_children():
		_check(await _reach(choice), "network reward %s is reachable" % choice.text.get_slice("\n", 0))
	_check_control(reward_skip, "network reward after choice navigation")
	session.snapshot.reward_options = []
	for card in [MIRROR_LUNGE, SHATTERGUARD, TACTICIANS_PAGE]:
		session.snapshot.reward_options.append({"id": String(card.id), "name": card.display_name,
			"cost": card.mana_cost, "description": card.description()})
	session.snapshot.merge({
		"encounter_id": 2, "encounter_count": 3, "enemy_name": "Goblin + Treant",
		"run_title": MULTI_ENEMY_RUN.title, "next_encounter_name": "Citadel Warden",
	}, true)
	session.changed.emit()
	await _settle()
	var run_stage := _control(scene, "%RunStage") as Label
	_check("Encounter 2 of 3" in run_stage.text and "Goblin + Treant" in run_stage.text
		and "Citadel Warden" in reward_status.text, "network reward shows the completed and next encounter")
	_check_control(run_stage, "multi-enemy network reward")
	_check_control(reward_status, "multi-enemy network reward")
	_check_control(reward_skip, "multi-enemy network reward")
	for choice: Button in reward_choices.get_children():
		_check(await _reach(choice), "long expanded network reward is reachable")
		_check_button_text(choice, "long expanded network reward")
	session.snapshot.merge({
		"run_stage": "portal", "encounter_id": 2, "encounter_count": 4, "enemy_name": "Two Slimes",
		"portal_ready": 0, "portal_submitted": false,
		"portal_options": PortalRoute.new(MULTI_ENEMY_RUN.run_seed).options(&"two_slimes"),
	}, true)
	session.snapshot.erase("reward_options")
	session.changed.emit()
	await _settle()
	var portal_status := _control(combat, "%PortalStatus") as Label
	_check("Choose a Portal" in run_stage.text and not reward.visible and combat.is_visible_in_tree()
		and reward_choices.get_child_count() == 0, "network portals appear after private rewards clear")
	_check_control(portal_status, "network portal progress")
	var portals := _control(combat, "%PortalChoices")
	_check(portals.get_child_count() == 2, "network portal view removed the previous reward buttons")
	for choice: Button in portals.get_children():
		_check(choice.has_meta(&"portal_id") and await _reach(choice), "network branch preview is reachable")
		_check_button_text(choice, "network portal preview")
	session.snapshot.portal_submitted = true
	session.snapshot.portal_ready = 1
	var selected_portal: String = session.snapshot.portal_options[0].id
	session.snapshot.portal_votes = {String(NAMES[0]): selected_portal}
	session.changed.emit()
	await _settle()
	_check((portals.get_child(0) as Button).disabled and "1/4" in portal_status.text,
		"network portal vote locks while waiting")
	_check(NAMES[0] in (portals.get_child(0).get_node("PortalVoters") as Label).text,
		"network portal associates the current vote with its Mage")
	await _close(scene)


func _test_network_enemy_picker(session: NetworkSession, combat: Control) -> void:
	# Give the fixture a status-test hand to include a targeted card without the Attack flag.
	var state := CombatState.new(THREE_ENEMIES, THREE_ENEMIES.shuffle_seed, NAMES, -1,
		{NAMES[0]: ENCOUNTER.test_deck})
	var goblin_state := state.enemy_state(&"goblin")
	goblin_state.block = 6
	goblin_state.strength = 2
	goblin_state.dexterity = 3
	goblin_state.poison = 4
	goblin_state.burning = 5
	session.snapshot = ViewSnapshot.build(state, THREE_ENEMIES, NAMES[0])
	session.snapshot["encounter_id"] = 1
	session.changed.emit()
	await _settle()
	var targets := _control(combat, "%EnemyTargets")
	var prompt := _control(combat, "%TargetLabel") as Label
	_check(targets.get_child_count() == 3 and not _control(combat, "%EnemyLabel").visible,
		"four-player network combat shows all three enemies in the target picker")
	for button: Button in targets.get_children():
		_check(await _reach(button), "network enemy display %s is reachable (rect %s)" %
			[button.text.get_slice("\n", 0), button.get_global_rect()])
		_check_button_text(button, button.text.get_slice("\n", 0) + "'s status and intent")
	var goblin := targets.get_child(1) as Button
	var treant := targets.get_child(2) as Button
	_check("Block 6" in goblin.text and "Poison 4" in goblin.text and "Burning 5" in goblin.text and
		"Dexterity 3" in goblin.text and "Strength 2" in goblin.text and "for 4 damage each" in goblin.text,
		"Goblin displays its own counters and effective attack")
	_check("Gain 6 Block" in treant.text and "Poison 4" not in treant.text,
		"Treant independently displays its Block intent")
	var targeted := _card(combat, "Test Toxic Spark")
	var alternative := _card(combat, "Test Ember Spark")
	var defensive := _card(combat, "Basic Block")
	_check(not targeted.disabled and not defensive.disabled and goblin.disabled,
		"both a targeted status card and a self card can be chosen before any enemy")

	var requests: Array[StringName] = []
	combat.network_card_requested.disconnect(session.submit_card)
	var record_target := func(_copy_id: int, target_id: StringName): requests.append(target_id)
	combat.network_card_requested.connect(record_target)
	if await _reach(defensive):
		_click(defensive)
		await _settle()
	if await _reach(alternative):
		_click(alternative)
		await _settle()
	_check(prompt.visible and prompt.text == "Choose a target for Test Ember Spark" and requests == [&""],
		"choosing a status card shows a prompt and emits no command")
	if await _reach(targeted):
		_click(targeted)
		await _settle()
	_check(prompt.visible and prompt.text == "Choose a target for Test Toxic Spark" and requests == [&""],
		"choosing another targeted card replaces the pending card")
	if await _reach(goblin):
		_click(goblin)
		await _settle()
	_check(not prompt.visible and goblin.disabled and requests == [&"", &"goblin"],
		"the target click emits the selected enemy ID and dismisses targeting")
	if await _reach(targeted):
		_click(targeted)
		await _settle()
	goblin_state.hp = 0
	session.snapshot = ViewSnapshot.build(state, THREE_ENEMIES, NAMES[0])
	session.snapshot["encounter_id"] = 1
	session.changed.emit()
	await _settle()
	goblin.pressed.emit()
	_check(goblin.disabled and "Defeated" in goblin.text and "Intent" not in goblin.text and
		prompt.visible and not treant.disabled and requests.size() == 2,
		"a target defeated by a teammate is rejected while remaining targets stay available")
	if await _reach(treant):
		_click(treant)
		await _settle()
	if await _reach(targeted):
		_click(targeted)
		await _settle()

	state.enemy_state(&"treant").hp = 0
	session.snapshot = ViewSnapshot.build(state, THREE_ENEMIES, NAMES[0])
	session.snapshot["encounter_id"] = 1
	session.changed.emit()
	await _settle()
	_check(prompt.visible and requests == [&"", &"goblin", &"treant"],
		"a pending card stays unspent if the enemy roster shrinks to one")
	if await _reach(targeted):
		_click(targeted)
		await _settle()
	_check(not prompt.visible and requests.size() == 3,
		"clicking the pending card again cancels even after the roster shrinks")
	if await _reach(targeted):
		_click(targeted)
		await _settle()
	_check(not prompt.visible and requests == [&"", &"goblin", &"treant", &"slime"],
		"a card click submits immediately when only one enemy survives")

	var next_state := CombatState.new(THREE_ENEMIES, THREE_ENEMIES.shuffle_seed, NAMES, -1,
		{NAMES[0]: ENCOUNTER.test_deck})
	session.snapshot = ViewSnapshot.build(next_state, THREE_ENEMIES, NAMES[0])
	session.snapshot["encounter_id"] = 1
	session.changed.emit()
	await _settle()
	if await _reach(targeted):
		_click(targeted)
		await _settle()
	_check(prompt.visible, "the same round can start another pending selection")
	session.snapshot = session.snapshot.duplicate()
	session.snapshot["encounter_id"] = 2
	session.changed.emit()
	await _settle()
	_check(not prompt.visible and not _card(combat, "Test Toxic Spark").disabled,
		"a new encounter clears the pending card even when enemy and card IDs are reused")
	_check_control(_control(combat, "%EndTurnButton"), "network enemy picker after targeting")
	combat.network_card_requested.disconnect(record_target)
	combat.network_card_requested.connect(session.submit_card)


func _test_network_ready(session: NetworkSession, combat: Control) -> void:
	var state := CombatState.new(THREE_ENEMIES, THREE_ENEMIES.shuffle_seed, NAMES)
	state.end_turn(NAMES[0])
	session.snapshot = ViewSnapshot.build(state, THREE_ENEMIES, NAMES[0])
	session.snapshot["encounter_id"] = 2
	session.changed.emit()
	await _settle()
	var end := _control(combat, "%EndTurnButton") as Button
	var hand := _control(combat, "%HandCards")
	_check(end.text == "Undo Ready · Battle Mage 1" and hand.get_child_count() == 5
		and hand.get_children().all(func(card: Button) -> bool: return card.disabled),
		"network Ready retains the disabled private hand and displays Undo Ready")
	_check_control(end, "network Undo Ready")
	combat.network_undo_ready_requested.disconnect(session.submit_undo_ready)
	var undos: Array[bool] = []
	var record_undo := func(): undos.append(true)
	combat.network_undo_ready_requested.connect(record_undo)
	_click(end)
	await _settle()
	_check(undos.size() == 1, "network Undo Ready emits its own command from viewport input")
	combat.network_undo_ready_requested.disconnect(record_undo)
	combat.network_undo_ready_requested.connect(session.submit_undo_ready)


func _test_long_hand(session: NetworkSession, combat: Control, snapshot: Dictionary) -> void:
	var expanded := snapshot.duplicate(true)
	for index in 4:
		expanded.hand.append({"copy": 100 + index, "id": String(REVERSAL.id), "name": REVERSAL.display_name,
			"cost": REVERSAL.mana_cost, "description": REVERSAL.description(), "approval": REVERSAL.approval_status,
			"attack": REVERSAL.is_attack, "playable": true})
	session.snapshot = expanded
	session.changed.emit()
	await _settle()
	var hand := _control(combat, "%HandCards")
	var last := hand.get_child(hand.get_child_count() - 1) as Button
	_check(last.text.begins_with("Arcane Reversal") and "lose 6 Block to deal 6 additional damage" in last.text,
		"expanded hand includes the complete Arcane Reversal rules text")
	last.grab_focus()
	await _settle()
	_check(last.has_focus() and _fully_visible(last), "focusing the last card scrolls its full button into view (rect %s)" %
		last.get_global_rect())
	_check_button_text(last, "Arcane Reversal's wrapped text")
	_check_control(_control(combat, "%EndTurnButton"), "expanded hand after last-card focus")


func _reward_snapshot(snapshot: Dictionary) -> Dictionary:
	var reward := snapshot.duplicate(true)
	var options: Array[Dictionary] = []
	for card in preload("res://resources/prototype/battle_mage_run.tres").reward_candidates:
		options.append({"id": String(card.id), "name": card.display_name, "cost": card.mana_cost,
			"description": card.description()})
	reward.merge({"run_stage": "reward", "encounter_id": 1, "reward_ready": 1, "reward_submitted": false,
		"reward_options": options, "phase": CombatState.Phase.VICTORY, "enemy_hp": 0,
		"can_end_turn": false, "can_undo_ready": false}, true)
	for enemy in reward.enemies:
		enemy.hp = 0
		enemy.alive = false
	return reward


func _check_combat(combat: Control, context: String) -> void:
	_check_control(_control(combat, "%EndTurnButton"), context)
	for path in ["%TurnLabel", "%PlayerLabel", "%EnemyLabel", "%CardsLabel"]:
		var label := _control(combat, path)
		_check(await _reach(label), "%s %s is readable (rect %s)" % [context, label.name, label.get_global_rect()])
	var hand := _control(combat, "%HandCards")
	_check(hand.get_child_count() == 5, "%s renders the full five-card opening hand" % context)
	for card in hand.get_children():
		_check(await _reach(card), "%s card %s is reachable (rect %s)" % [context, card.text.get_slice("\n", 0), card.get_global_rect()])
	_check_control(_control(combat, "%EndTurnButton"), context + " after hand navigation")


func _check_button_text(button: Button, context: String) -> void:
	var style := button.get_theme_stylebox("normal")
	var padding := style.get_minimum_size()
	var paragraph := TextParagraph.new()
	paragraph.width = button.size.x - padding.x
	paragraph.break_flags = TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE
	paragraph.add_string(button.text, button.get_theme_font("font"), button.get_theme_font_size("font_size"))
	var text_height := paragraph.get_size().y
	_check(text_height <= button.size.y - padding.y + 1.0,
		"%s fits (%0.1f of %0.1f usable pixels)" % [context, text_height, button.size.y - padding.y])


func _control(scene: Node, path: NodePath) -> Control:
	return scene.get_node(path) as Control


func _card(combat: Node, name_prefix: String) -> Button:
	for card in _control(combat, "%HandCards").get_children():
		if card.text.begins_with(name_prefix):
			return card
	return null


func _open(scene: PackedScene) -> Control:
	var instance := scene.instantiate() as Control
	_viewport.add_child(instance)
	await _settle()
	return instance


func _close(scene: Control) -> void:
	scene.queue_free()
	await _settle()


func _settle() -> void:
	for frame in 5:
		await process_frame


func _click(control: Control, double_click := false) -> void:
	var position := control.get_global_rect().get_center()
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = position
	event.global_position = position
	event.pressed = true
	event.double_click = double_click
	_viewport.push_input(event, true)
	event.pressed = false
	event.double_click = false
	_viewport.push_input(event, true)


func _reach(control: Control) -> bool:
	var parent := control.get_parent()
	while parent is Control and not _fully_visible(control):
		if parent is ScrollContainer:
			parent.ensure_control_visible(control)
			await _settle()
		parent = parent.get_parent()
	return _fully_visible(control)


func _fully_visible(control: Control) -> bool:
	var rect := control.get_global_rect()
	if not control.is_visible_in_tree() or not rect.has_area() or not Rect2(Vector2.ZERO, Vector2(_size)).encloses(rect):
		return false
	var parent := control.get_parent()
	while parent is Control:
		if parent.clip_contents and not parent.get_global_rect().encloses(rect):
			return false
		parent = parent.get_parent()
	return true


func _check_control(control: Control, context: String) -> void:
	var enabled: bool = not (control is Button and (control as Button).disabled)
	_check(_fully_visible(control) and enabled, "%s %s fits viewport (rect %s)" %
		[context, control.name, control.get_global_rect()])


func _check(condition: bool, context: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("%dx%d %s" % [_size.x, _size.y, context])
