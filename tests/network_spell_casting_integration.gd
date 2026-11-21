extends SceneTree

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const BattleMagePool = preload("res://scripts/run/battle_mage_pool_playtest.gd")
const CombatView = preload("res://scripts/combat.gd")
const CoopRun = preload("res://scripts/run/coop_run_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const NetworkSession = preload("res://scripts/network/network_coop_session.gd")
const RuneCanvas = preload("res://scripts/ui/rune_canvas.gd")
const NETWORK_COMBAT = preload("res://scenes/network_coop.tscn")
const MULTI_ENEMY_RUN = preload("res://resources/prototype/multi_enemy_run.tres")
const TWO_SLIMES = preload("res://resources/prototype/enemies/two_slimes.tres")
const SETTINGS = preload("res://resources/prototype/spell_drawing_settings.tres")
const SALVO = preload("res://resources/prototype/cards/expansion/astral_salvo.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const BLOCK = preload("res://resources/prototype/cards/basic_block.tres")
const BOOSTER = preload("res://resources/prototype/cards/spell_ink_booster.tres")
const BOOSTED_SEAT := 2
const STARTING_ENEMY_HP := 70

var _session: NetworkSession
var _combat: CombatView
var _viewport: SubViewport
var _network_view: Control
var _seat: int
var _size: int
var _viewer: String
var _release: String
var _short_run := false
var _ready_reported := false
var _disconnect_intended := false
var _failed := false
var _last_revision := -1
var _public_frames := PackedStringArray()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 4 and (args.size() != 5 or args[4] != "ShortRun"):
		_fail("Expected port, party size, seat, release file, and optional ShortRun.")
		return
	_short_run = args.size() == 5
	_size = int(args[1])
	_seat = int(args[2])
	_viewer = "Battle Mage %d" % _seat
	_release = args[3]
	var mode := RuneCanvas.DrawingMode.HOLD if _seat % 2 == 1 else RuneCanvas.DrawingMode.TOGGLE
	RuneCanvas.session_input_mode = mode
	_viewport = SubViewport.new()
	_viewport.name = "CastViewport"
	_viewport.size = Vector2i(1280, 720)
	root.add_child(_viewport)
	_network_view = NETWORK_COMBAT.instantiate()
	_viewport.add_child(_network_view)
	_session = _network_view.get_node("Session")
	_combat = _network_view.get_node("%CombatSlot/Combat")
	_session.changed.connect(_observe)
	_session.command_result.connect(_on_result)
	if _seat == 1:
		_session.encounter = _fixture()
		_session.spell_drawing = SETTINGS
		if _short_run:
			var run := BattleMagePool.with_expanded_rewards(MULTI_ENEMY_RUN)
			run.major_arcana_enabled = true
			run.portal_enabled = true
			var opening := _fixture(6)
			run.opening_encounters.assign([opening])
			run.starting_deck.assign([STRIKE, STRIKE, BLOCK, BLOCK, BOOSTER])
			_session.run_data = run
	var error := _session.host(int(args[0]), _size, _short_run) if _seat == 1 else _session.join(int(args[0]))
	if not _check(error == OK, "could not open localhost session"):
		return
	if not await _wait_until(func() -> bool: return _session.status == NetworkSession.Status.ACTIVE,
			"the full party to enter combat", 20_000):
		return
	if _short_run:
		await _play_short_run(mode)
	else:
		await _play_standalone(mode)


func _play_standalone(mode: RuneCanvas.DrawingMode) -> void:
	if _seat == BOOSTED_SEAT and not _play_card("spell_ink_booster"):
		return
	if not await _wait_until(func() -> bool: return _last_revision >= 1, "instant Booster resolution"):
		return
	if not _check(_cast().is_empty() and not _panel_visible(), "Booster resolves without revealing a drawing panel"):
		return
	var spell := "astral_salvo" if _seat == BOOSTED_SEAT else "basic_strike"
	var target := 1 if _seat == BOOSTED_SEAT else 0
	var drawing_copy := _find_card(spell)
	if not _play_card(spell, target) or not await _wait_until(_surface_ready, "drawing workspace to become usable"):
		return
	var active_cast := _cast()
	var cast_context: Label = _combat._spell_panel.get_node("%CastContext")
	var rune_name: Label = _combat._spell_panel.get_node("%RuneName")
	if not _check(active_cast.copy == drawing_copy and active_cast.target == "slime_%d" % (target + 1)
			and active_cast.boosted == (_seat == BOOSTED_SEAT) and _last_revision == 1
			and _viewer in cast_context.text and "Slime" in cast_context.text
			and ("extra stroke" in rune_name.text) == (_seat == BOOSTED_SEAT),
			"host opened the private card/target with a seat-specific enhancement and no combat mutation"):
		return
	if not await _barrier("drawing"):
		return
	# No peer submits before every workspace has opened. This proves simultaneous
	# pending draws and catches global locks, even with only one remote client.
	if not _draw_cast(mode, SALVO.rune_template.strokes.size() + 1 if _seat == BOOSTED_SEAT else 1):
		return
	if not await _wait_until(func() -> bool: return _last_revision == _size + 1, "all authoritative spells to resolve"):
		return
	if not _verify_cast_results(drawing_copy):
		return
	if not await _barrier("resolved"):
		return

	if not _check(_session.submit_end_turn(), "each peer can Ready after its cast"):
		return
	if not await _wait_until(func() -> bool: return _session.snapshot.get("round") == 2,
			"the next player phase after everyone is Ready"):
		return
	if not _play_card("basic_block") or not await _wait_until(_surface_ready, "a fresh cast in round two"):
		return
	if _seat == 1:
		var prior_hand: Array = _session.snapshot.hand.map(func(card: Dictionary) -> int: return card.copy)
		var prior_mana: int = _session.snapshot.players[0].mana
		var prior_token: String = _cast().token
		(_combat._spell_panel.get_node("%CancelButton") as Button).pressed.emit()
		if not await _wait_until(func() -> bool: return _cast().is_empty() and not _panel_visible(), "cancellation"):
			return
		if not _check(prior_hand == _session.snapshot.hand.map(func(card: Dictionary) -> int: return card.copy)
				and prior_mana == _session.snapshot.players[0].mana, "cancellation preserves the original card and Mana"):
			return
		if not _play_card("basic_block") or not await _wait_until(_surface_ready, "new cast after canceling"):
			return
		if not _check(_cast().token != prior_token, "reopening the same card issues a new token"):
			return

	if not _check(_surface_ready(), "the party disconnects while each seat has an active workspace"):
		return
	_disconnect_intended = true
	if not await _barrier("disconnect"):
		return
	if _seat == BOOSTED_SEAT:
		_network_view.queue_free()
		await _network_view.tree_exited
	else:
		if not await _wait_until(func() -> bool: return _session.status == NetworkSession.Status.DISCONNECTED,
				"the host or other client to observe the real disconnect"):
			return
		if not _check(not _panel_visible() and _cast().is_empty() and _session._authority == null,
				"disconnection clears the private workspace and any remaining authority"):
			return
	await _finish("concurrent drawings · round advance · disconnect cleanup")


func _play_short_run(mode: RuneCanvas.DrawingMode) -> void:
	var arcana: Array = _session.snapshot.get("arcana_options", [])
	if not _check(_session.snapshot.run_stage == CoopRun.ARCANA and not arcana.is_empty(),
			"the opening offers arrive through the private Arcana stage"):
		return
	var arcana_id: String = arcana[0].id
	if not _check(_session.submit_arcana(arcana_id), "choose personal Arcana"):
		return
	if not await _wait_until(func() -> bool: return _session.snapshot.run_stage == CoopRun.OPENING, "the opening fight"):
		return
	if not _check(_session.snapshot.arcana.id == arcana_id and _session.submit_end_turn(),
			"the chosen Arcana is active and the party can play through an enemy phase"):
		return
	if not await _wait_until(func() -> bool: return _session.snapshot.get("round") == 2, "opening round two"):
		return
	if _seat in [1, 2]:
		if not _play_card("basic_strike", _seat - 1) or not await _wait_until(_surface_ready, "opening rune"):
			return
	if not await _barrier("opening"):
		return
	if _seat in [1, 2] and not _draw_cast(mode, 1):
		return
	if not await _wait_until(func() -> bool: return _session.snapshot.run_stage == CoopRun.REWARD, "private rewards"):
		return
	var reward: Array = _session.snapshot.get("reward_options", [])
	var deck_size: int = _session.snapshot.run_deck_count
	var carried_hp: int = _session.snapshot.players[_seat - 1].hp
	var overlay := _combat.get("reward_overlay") as Control
	var reward_buttons := overlay.get_node("%RewardChoices")
	if not _check(not reward.is_empty() and _cast().is_empty() and not _panel_visible()
			and _combat.is_visible_in_tree() and overlay.is_visible_in_tree()
			and reward_buttons.get_child_count() == reward.size(),
			"opening victory closes the modal and presents only the assigned reward choices"):
		return
	var draft := (reward_buttons.get_child(0) if _seat == 1 else overlay.get_node("%SkipReward")) as Button
	if not _check(draft.is_visible_in_tree() and not draft.disabled, "one seat can take a rune card and others can skip"):
		return
	draft.pressed.emit()
	if not await _wait_until(func() -> bool: return _session.snapshot.run_stage == CoopRun.PORTAL, "the portal vote"):
		return
	var portals: Array = _session.snapshot.get("portal_options", [])
	var portal_controls := _combat.get_node("%PortalChoices") as Control
	if not _check(not portals.is_empty() and portals[0].type == "Normal Encounter" and not portals[0].has("name")
			and not _session.snapshot.has("reward_options") and not overlay.visible
			and reward_buttons.get_child_count() == 0 and portal_controls.is_visible_in_tree(),
			"the physical gate appears on the same battlefield after the private reward view clears"):
		return
	var portal := portal_controls.get_child(0) as Button
	if not _check(portal.get_meta("portal_id") == portals[0].id and not portal.disabled, "select the physical portal"):
		return
	await process_frame
	await process_frame
	var portal_art := portal.get_node("PortalArt") as Control
	var position := portal_art.get_global_rect().get_center()
	_mouse_button(position, true)
	_mouse_button(position, false)
	if not await _wait_until(func() -> bool: return _session.snapshot.get("encounter_id") == 2,
			"the selected next encounter"):
		return
	if not _check(_session.snapshot.run_stage == CoopRun.INTERMEDIATE and _session.snapshot.round == 1
			and _session.snapshot.arcana.id == arcana_id and _session.snapshot.players[_seat - 1].hp == carried_hp
			and _session.snapshot.run_deck_count == deck_size + int(_seat == 1) and _cast().is_empty(),
			"the portal preserves personal HP, Arcana, and reward, and starts fresh combat"):
		return
	if not _play_card("basic_block") or not await _wait_until(_surface_ready, "a new workspace after the portal"):
		return
	if not _draw_cast(mode, 1):
		return
	if not await _wait_until(func() -> bool: return _session.snapshot.revision == _size, "all new encounter rune results"):
		return
	if not _check(_session.snapshot.players[_seat - 1].block == 6 and _session.snapshot.players[_seat - 1].mana == 2
			and not _panel_visible() and _cast().is_empty(), "the new workspace successfully resolves one cast per seat"):
		return
	await _finish("Arcana · private rewards · portal transition · fresh casts")


func _draw_cast(mode: RuneCanvas.DrawingMode, expected_strokes: int) -> bool:
	var panel := _combat._spell_panel
	var canvas := panel.get_node("%RuneCanvas") as RuneCanvas
	if not _check(canvas._input_mode == mode and _surface_ready(), "each peer retains its own drawing mode"):
		return false
	var routine_strokes: Array[PackedVector2Array] = []
	routine_strokes.assign(_cast().guide)
	if not _check(routine_strokes.size() == expected_strokes, "the seat received the correct base or augmented guide"):
		return false
	# Reverse both component order and tracing direction to exercise the normal matcher.
	routine_strokes.reverse()
	for path in routine_strokes:
		var points := canvas.get_global_transform_with_canvas() * canvas._local_points(path)
		points.reverse()
		_trace(points, mode)
	var cast_button: Button = panel.get_node("%SubmitButton")
	if not _check(canvas.completed_strokes().size() == routine_strokes.size() and not cast_button.disabled,
			"input mode captured %d of %d strokes (Cast disabled: %s)" %
				[canvas.completed_strokes().size(), routine_strokes.size(), cast_button.disabled]):
		return false
	cast_button.pressed.emit()
	return true


func _finish(summary: String) -> void:
	_disconnect_intended = true
	print("RESULT %d matching public revisions · %s · %s" % [
		_public_frames.size(), summary, "\n".join(_public_frames).sha256_text()])
	while not FileAccess.file_exists(_release):
		await create_timer(0.04).timeout
	# End the live short-run session from the host before clients exit together.
	if _short_run and _seat != 1 and not await _wait_until(func() -> bool:
			return _session.status == NetworkSession.Status.DISCONNECTED, "host shutdown after result"):
		return
	quit()


func _fixture(enemy_hp := STARTING_ENEMY_HP) -> EncounterData:
	var encounter: EncounterData = TWO_SLIMES.duplicate(true)
	encounter.test_deck.assign(SETTINGS.test_deck)
	for enemy in encounter.enemies:
		enemy.max_hp = enemy_hp
	return encounter


func _observe() -> void:
	if not _ready_reported and _session.status in [NetworkSession.Status.HOSTING, NetworkSession.Status.WAITING]:
		_ready_reported = true
		print("SEAT_READY ", _seat)
	if _session.status == NetworkSession.Status.DISCONNECTED and not _disconnect_intended:
		_fail(_session.message)
	if _session.status != NetworkSession.Status.ACTIVE:
		return
	var view := _session.snapshot
	var players: Array = view.get("players", [])
	if not _check(view.viewer == _viewer and (players.size() == _size or view.get("run_stage") == CoopRun.ARCANA)
			and not view.has("seed"),
			"only the assigned player receives a private view"):
		return
	for player: Dictionary in players:
		if not _check(not player.has("hand") and not player.has("cast") and not player.has("token")
				and not player.has("guide") and not player.has("reward_options"), "public player rows stay public"):
			return
	for card: Dictionary in view.get("hand", []):
		var offset := 0 if _short_run else (_seat - 1) * SETTINGS.test_deck.size()
		var count: int = view.get("run_deck_count", SETTINGS.test_deck.size())
		if not _check(card.copy >= offset and card.copy < offset + count,
				"the snapshot hand contains only the authenticated seat's copies"):
			return
	if not _cast().is_empty() and not _check(view.hand.any(func(card: Dictionary) -> bool:
			return card.copy == _cast().copy), "any drawing context in the snapshot belongs to this hand"):
		return
	var revision: int = view.get("run_revision", view.revision)
	if revision <= _last_revision:
		return
	_last_revision = revision
	_public_frames.append(JSON.stringify({"players": players, "enemies": view.get("enemies"),
		"round": view.get("round"), "phase": view.get("phase"), "revision": revision, "log": view.get("log"),
		"stage": view.get("run_stage"), "encounter": view.get("encounter_id"), "arcana_ready": view.get("arcana_ready"),
		"reward_ready": view.get("reward_ready"), "portal_options": view.get("portal_options"),
		"portal_ready": view.get("portal_ready")}).sha256_text())


func _on_result(_sequence: int, result: int) -> void:
	if result != Authority.Result.ACCEPTED:
		_fail("Host rejected legal player input (%s)." % Authority.Result.keys()[result])


func _verify_cast_results(copy_id: int) -> bool:
	var view := _session.snapshot
	var actor: Dictionary = view.players[_seat - 1]
	var log := "\n".join(view.log)
	var expected_power := 130 if _seat == BOOSTED_SEAT else 110
	return _check(view.enemies[0].hp == STARTING_ENEMY_HP - 7 * (_size - 1)
		and view.enemies[1].hp == STARTING_ENEMY_HP - 18
		and actor.mana == (0 if _seat == BOOSTED_SEAT else 2)
		and view.discard_count == (2 if _seat == BOOSTED_SEAT else 1)
		and view.hand.all(func(card: Dictionary) -> bool: return card.copy != copy_id)
		and _cast().is_empty() and not _panel_visible() and view.round == 1
		and "Excellent cast" in _combat.spell_feedback.text
		and ("%d%% base power" % expected_power) in _combat.spell_feedback.text
		and log.count("130% base power") == 1 and log.count("110% base power") == _size - 1,
		"all exact draws resolve once in the same shared phase with host-derived power and intended targets")


func _find_card(id: String) -> int:
	for card: Dictionary in _session.snapshot.hand:
		if card.id == id:
			return card.copy
	return -1


func _play_card(id: String, target := -1) -> bool:
	var button: Button = _combat._card_buttons.get(_find_card(id))
	if not _check(button != null and not button.disabled, "playable card has a usable button: " + id):
		return false
	button.pressed.emit()
	if target >= 0:
		var picker := _combat.get_node("%EnemyTargets")
		var enemy := picker.get_child(target) as Button
		if not _check(not enemy.disabled and _cast().is_empty(), "card-first targeting opens before a cast is granted"):
			return false
		enemy.pressed.emit()
	return true


func _cast() -> Dictionary:
	return _session.snapshot.get("cast", {})


func _panel_visible() -> bool:
	return is_instance_valid(_combat._spell_panel) and _combat._spell_panel.is_visible_in_tree()


func _surface_ready() -> bool:
	return not _cast().is_empty() and _panel_visible() and _combat._spell_panel._deadline_ms > Time.get_ticks_msec()


func _trace(points: PackedVector2Array, mode: RuneCanvas.DrawingMode) -> void:
	_viewport.push_input(_mouse_motion(points[0], 0), true)
	if mode == RuneCanvas.DrawingMode.TOGGLE:
		_tap_toggle()
		for point in points:
			_viewport.push_input(_mouse_motion(point, 0), true)
		_tap_toggle()
	else:
		_mouse_button(points[0], true)
		for point in points:
			_viewport.push_input(_mouse_motion(point, MOUSE_BUTTON_MASK_LEFT), true)
		_mouse_button(points[-1], false)


func _mouse_motion(position: Vector2, mask: int) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	event.button_mask = mask
	return event


func _mouse_button(position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	_viewport.push_input(event, true)


func _tap_toggle() -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = KEY_X
		event.pressed = pressed
		_viewport.push_input(event, true)


func _barrier(label: String) -> bool:
	var marker := FileAccess.open(_release + ".%s-%d" % [label, _seat], FileAccess.WRITE)
	if not _check(marker != null, "could not create synchronization marker"):
		return false
	marker.close()
	return await _wait_until(func() -> bool:
		for seat in range(1, _size + 1):
			if not FileAccess.file_exists(_release + ".%s-%d" % [label, seat]):
				return false
		return true, "all seats to reach " + label)


func _wait_until(predicate: Callable, reason: String, timeout_ms := 4000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not _failed and not predicate.call():
		if Time.get_ticks_msec() >= deadline:
			_fail("Timed out waiting for " + reason)
			return false
		await process_frame
	return not _failed


func _check(condition: bool, message: String) -> bool:
	if not condition:
		_fail(message)
	return condition


func _fail(message: String) -> void:
	_failed = true
	push_error("%s: %s" % [_viewer, message])
	quit(1)
