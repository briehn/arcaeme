extends SceneTree

const COMBAT = preload("res://scenes/combat.tscn")
const LOCAL_COOP = preload("res://scenes/local_coop.tscn")
const TWO_SLIMES = preload("res://resources/prototype/enemies/two_slimes.tres")
const THREE_ENEMIES = preload("res://resources/prototype/enemies/three_enemies.tres")
const DRAWING = preload("res://resources/prototype/spell_drawing_settings.tres")
const BACKDROP = preload("res://resources/prototype/encounter_backdrop.tres")
const Authority = preload("res://scripts/network/network_combat_authority.gd")
const DISPLAY_SIZES := [Vector2i(960, 540), Vector2i(1024, 576), Vector2i(1280, 720), Vector2i(1920, 1080)]

var _viewport: SubViewport
var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for resolution: Vector2i in DISPLAY_SIZES:
		_viewport = SubViewport.new()
		_viewport.size = resolution
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(_viewport)
		await _test_single_enemy()
		await _test_local_targeting()
		for count in range(2, 5):
			await _test_network_view(count)
		await _test_casting()
		_viewport.queue_free()
		await process_frame
	print("Battlefield presentation: %d checks at %d viewport sizes, %d failures." % [
		_checks, DISPLAY_SIZES.size(), _failures])
	quit(int(_failures > 0))


func _test_single_enemy() -> void:
	var combat = COMBAT.instantiate()
	_viewport.add_child(combat)
	await _settle()
	var single := combat.get_node("%SingleEnemy") as Control
	var glyph := single.get_child(0) as Control
	var details := combat.get_node("%EnemyLabel") as Label
	_check(glyph.is_visible_in_tree() and _onscreen(glyph) and glyph._kind == "training golem"
		and details.text.begins_with("Training Golem") and "Intent: Attack" in details.text,
		"single enemy has a visible matching glyph and intent")
	_check_party(combat, 1, 0)
	var background := combat.get_node("EncounterBackdrop") as TextureRect
	_check(background.texture == BACKDROP and background.get_global_rect() == Rect2(Vector2.ZERO, Vector2(_viewport.size)),
		"reusable gradient fills the encounter")
	await _close(combat)


func _test_local_targeting() -> void:
	var combat = LOCAL_COOP.instantiate()
	combat.encounter = TWO_SLIMES
	_viewport.add_child(combat)
	await _settle()
	_check_party(combat, 2, 0)
	var targets := combat.get_node("%EnemyTargets") as Control
	var first := targets.get_child(0) as Button
	var second := targets.get_child(1) as Button
	var second_glyph := second.get_node("Silhouette") as Control
	_check(first.disabled and second.disabled and first.text.begins_with("Slime (1)")
		and second.text.begins_with("Slime (2)"), "duplicate enemies have distinct displays and wait for card selection")
	await _choose_strike(combat)
	_check(not first.disabled and not second.disabled and first.has_focus(), "targeting enables and focuses living enemies")
	_click(second_glyph)
	await _settle()
	_check("HP 18/18" in first.text and "HP 16/22" in second.text,
		"clicking the enemy glyph deals damage only to the chosen instance")
	await _close(combat)


func _test_network_view(count: int) -> void:
	var assignments: Dictionary[int, StringName] = {}
	for index in count:
		assignments[index + 1] = StringName("Battle Mage %d" % (index + 1))
	var authority := Authority.new(THREE_ENEMIES, assignments)
	var combat = COMBAT.instantiate()
	combat.configure_network()
	_viewport.add_child(combat)
	var snapshot := authority.snapshot_for(count)
	snapshot.enemies[0].alive = false
	snapshot.enemies[0].hp = 0
	snapshot.enemies[1].poison = 2
	combat.display_network_snapshot(snapshot, true)
	await _settle()
	_check_party(combat, count, count - 1)
	var targets := combat.get_node("%EnemyTargets") as Control
	var kinds: Array[String] = []
	for button: Button in targets.get_children():
		var glyph := button.get_node("Silhouette") as Control
		kinds.append(glyph._kind)
		_check(_onscreen(glyph) and button.get_global_rect().encloses(glyph.get_global_rect()),
			"%s glyph fits inside its enemy control" % glyph._kind)
	_check(kinds == ["slime", "goblin", "treant"], "all three enemy kinds have matching silhouettes")
	var first := targets.get_child(0) as Button
	var goblin := targets.get_child(1) as Button
	var treant := targets.get_child(2) as Button
	_check(first.disabled and "Defeated" in first.text and not first.get_node("Silhouette")._alive,
		"defeated enemy has an inactive glyph and retains its identity")
	_check("Poison 2" in goblin.text and "Intent: Attack" in goblin.text and "Gain 6 Block" in treant.text,
		"status and independent attack and defense intents remain readable")
	if count == 4:
		await _capture("network-battlefield")
	await _close(combat)


func _test_casting() -> void:
	var combat = COMBAT.instantiate()
	combat.encounter = TWO_SLIMES
	combat.spell_drawing = DRAWING
	_viewport.add_child(combat)
	await _settle()
	await _choose_strike(combat)
	var second := combat.get_node("%EnemyTargets").get_child(1) as Button
	_click(second.get_node("Silhouette") as Control)
	await _settle()
	var panel := combat._spell_panel as Control
	var context := panel.get_node("%CastContext") as Label
	_check(panel.is_visible_in_tree() and panel.size == Vector2(_viewport.size) and "Slime (2)" in context.text,
		"casting overlay fills the viewport and identifies the clicked enemy")
	await _capture("casting")
	await _close(combat)


func _check_party(combat: Control, count: int, active: int) -> void:
	var party := combat.get_node("%MageSilhouettes") as Control
	var opponents := combat.get_node("%SingleEnemy") as Control if count == 1 else combat.get_node("%EnemyTargets") as Control
	# Solo casting fixtures can also have multiple enemies.
	if not opponents.visible:
		opponents = combat.get_node("%EnemyTargets") as Control
	_check(party.get_child_count() == count and party.get_global_rect().end.x <= opponents.get_global_rect().position.x,
		"all %d Mage glyphs appear to the left of the opposition" % count)
	for index in count:
		var glyph := party.get_child(index) as Control
		_check(_onscreen(glyph) and glyph._seat == index + 1 and glyph._active == (index == active),
			"seat %d is visible and the current viewer has the active ring" % (index + 1))


func _choose_strike(combat: Control) -> void:
	for card: Button in combat.get_node("%HandCards").get_children():
		if card.text.begins_with("Basic Strike"):
			var scroll := combat.find_child("CombatScroll") as ScrollContainer
			scroll.ensure_control_visible(card)
			await _settle()
			_click(card)
			await _settle()
			return
	_check(false, "fixture has a Basic Strike to choose")


func _click(control: Control) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = control.get_global_rect().get_center()
	event.global_position = event.position
	event.pressed = true
	_viewport.push_input(event, true)
	event.pressed = false
	_viewport.push_input(event, true)


func _onscreen(control: Control) -> bool:
	var position := control.get_global_rect()
	return position.has_area() and Rect2(Vector2.ZERO, Vector2(_viewport.size)).encloses(position)


func _settle() -> void:
	for frame in 5:
		await process_frame


func _close(scene: Control) -> void:
	scene.queue_free()
	await process_frame


func _capture(label: String) -> void:
	if DisplayServer.get_name() == "headless" or "--capture" not in OS.get_cmdline_user_args():
		return
	await process_frame
	await RenderingServer.frame_post_draw
	var path := OS.get_environment("TEMP").path_join("arcaeme-m22a-%s-%dx%d.png" % [
		label, _viewport.size.x, _viewport.size.y])
	_check(_viewport.get_texture().get_image().save_png(path) == OK, "native capture succeeds")
	print("BATTLEFIELD_CAPTURE ", path)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("%s: %s" % [_viewport.size, message])
