extends SceneTree

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const DATA = preload("res://resources/prototype/local_coop_encounter.tres")
const RunData = preload("res://scripts/run/run_data.gd")
const CardData = preload("res://scripts/combat/card_data.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const RUN = preload("res://resources/prototype/battle_mage_run.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const TWO_SLIMES = preload("res://resources/prototype/enemies/two_slimes.tres")
const SETTINGS = preload("res://resources/prototype/spell_drawing_settings.tres")
const StrokePayload = preload("res://scripts/network/rune_stroke_payload.gd")
const ASSIGNMENTS: Dictionary[int, StringName] = {1: &"Battle Mage 1", 20: &"Battle Mage 2"}
const NOW := 20_000

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_authority_and_privacy()
	_test_waiting_staleness_and_replay()
	_test_short_run_authority()
	_test_network_cast_quality()
	_test_network_cast_validation()
	_test_network_cast_run_cleanup()
	_test_network_cast_target_and_defeat()
	_test_network_booster_fallback()
	print("Network combat authority: %d checks, %d failures." % [_checks, _failures])
	quit(1 if _failures else 0)


func _test_authority_and_privacy() -> void:
	var authority := Authority.new(DATA, ASSIGNMENTS)
	var host := authority.snapshot_for(1)
	var client := authority.snapshot_for(20)
	_check(host.viewer == "Battle Mage 1" and client.viewer == "Battle Mage 2" and host.players == client.players,
		"each connection has one distinct actor and sees the same public players")
	_check(authority.snapshot_for(3).is_empty() and client.hand.size() == 5 and host.hand.size() == 5 and host.hand != client.hand,
		"only assigned peers receive their own hand")
	for row in client.players:
		_check(not row.has("hand") and not row.has("deck") and not row.has("draw_pile") and not row.has("discard_pile"),
			"public player rows omit individual card information")
	_check(not client.has("seed") and not "Seed" in "\n".join(client.log), "client state omits the RNG seed")
	var request := _play_request(client, 1, _card(client, "basic_strike"))
	_check(authority.submit(3, request) == Authority.Result.UNKNOWN_PEER, "unassigned peers cannot play")
	var forged := request.duplicate()
	forged.actor = host.viewer
	_check(authority.submit(20, forged) == Authority.Result.WRONG_PLAYER, "a claimed actor cannot override peer assignment")
	_check(authority.submit(20, 1) == Authority.Result.MALFORMED, "reject a non-dictionary request")
	var invalid_field := request.duplicate()
	invalid_field["damage"] = 100
	_check(authority.submit(20, invalid_field) == Authority.Result.MALFORMED, "reject client-supplied combat values")
	invalid_field = request.duplicate()
	invalid_field["copy"] = "1"
	_check(authority.submit(20, invalid_field) == Authority.Result.MALFORMED, "reject an invalid copy ID type")
	_check(authority.submit(20, request) == Authority.Result.ACCEPTED, "the client can take the first action")
	_check(authority.submit(20, request) == Authority.Result.DUPLICATE, "reject a repeated accepted sequence")
	var after := authority.snapshot_for(20)
	_check(after.enemy_hp == 36 and after.players[0].mana == 3 and after.players[1].mana == 2 and after.revision == 1,
		"the authorized play spends only its owner's Mana and damages the enemy once")
	_check(authority.submit(20, _play_request(after, 2, _card(host, "shieldstrike"))) == Authority.Result.ILLEGAL_ACTION and
		authority.submit(20, _play_request(after, 3, -50)) == Authority.Result.ILLEGAL_ACTION,
		"reject foreign and invalid card copies")
	_check(authority.submit(20, _play_request(after, 4, _card(after, "arcane_reversal"))) == Authority.Result.ACCEPTED,
		"play the client's own Arcane Reversal")
	for i in 2:
		var view := authority.snapshot_for(20)
		var expected := Authority.Result.ACCEPTED if i == 0 else Authority.Result.ILLEGAL_ACTION
		_check(authority.submit(20, _play_request(view, i + 5, _card(view, "basic_block"))) == expected,
			"the resolver owns the Mana limit")
	_check(authority.snapshot_for(20).revision == 3 and authority.snapshot_for(20).players[1].block == 5,
		"rejection leaves combat state unchanged")


func _test_waiting_staleness_and_replay() -> void:
	var first := Authority.new(DATA, ASSIGNMENTS)
	var replay := Authority.new(DATA, ASSIGNMENTS)
	var commands := [
		[1, _play_request(first.snapshot_for(1), 1, _card(first.snapshot_for(1), "arcane_guard"))],
		[20, _play_request(first.snapshot_for(20), 1, _card(first.snapshot_for(20), "basic_strike"))],
		[1, _end_request(first.snapshot_for(1), 2)],
		[20, _end_request(first.snapshot_for(20), 2)],
	]
	for command in commands:
		_check(first.submit(command[0], command[1]) == Authority.Result.ACCEPTED and
			replay.submit(command[0], command[1]) == Authority.Result.ACCEPTED, "accept the same ordered command in both encounters")
		if command[0] == 1 and command[1].kind == Authority.Command.END_TURN:
			var waiting := first.snapshot_for(1)
			_check(waiting.round == 1 and waiting.players[0].ended_turn and not waiting.players[1].ended_turn,
				"the host can act and end first, but combat waits for the client")
			_check(first.submit(1, _end_request(waiting, 3)) == Authority.Result.ILLEGAL_ACTION,
				"an ended actor cannot submit again in the same round")
	var result := first.snapshot_for(20)
	_check(result == replay.snapshot_for(20) and first.snapshot_for(1) == replay.snapshot_for(1),
		"matching accepted commands and seed yield identical snapshots")
	_check(result.round == 2 and result.players[0].hp == 19 and result.players[1].hp == 12 and
		result.players[1].mana == 3 and result.hand.size() == 5, "enemy attacks both, then both players refresh")
	var stale := commands.back()[1] as Dictionary
	stale = stale.duplicate()
	stale.sequence = 3
	_check(first.submit(20, stale) == Authority.Result.STALE_TURN and first.snapshot_for(20) == result,
		"a new sequence cannot revive a command from the previous round")
	_check(first.submit(20, _end_request(result, 2)) == Authority.Result.DUPLICATE,
		"a reused sequence is rejected even when it names a fresh round")
	var wrong_phase := _end_request(result, 4)
	wrong_phase.phase = result.phase + 1
	_check(first.submit(20, wrong_phase) == Authority.Result.STALE_TURN and first.snapshot_for(20) == result,
		"the round alone does not authorize an action for the wrong phase")


func _card(snapshot: Dictionary, id: String) -> int:
	for card in snapshot.hand:
		if card.id == id:
			return card.copy
	return -1


func _test_short_run_authority() -> void:
	var fixture: RunData = RUN.duplicate()
	var opening: EncounterData = RUN.opening_encounters[0].duplicate()
	opening.enemy_max_hp = 6
	fixture.opening_encounters = [opening]
	fixture.starting_deck = [STRIKE]
	var universal: CardData = STRIKE.duplicate()
	universal.id = &"test_universal"
	universal.owner_class_id = &"universal"
	fixture.reward_candidates = [universal, RUN.reward_candidates[0], RUN.reward_candidates[0]]
	var authority := Authority.new(DATA, ASSIGNMENTS, fixture)
	var first := authority.snapshot_for(1)
	var play := _play_request(first, 1, _card(first, "basic_strike"))
	_check(first.encounter_id == 1 and first.run_stage == "opening" and not first.has("reward_options"),
		"opening publishes the encounter identity before exposing rewards")
	_check(authority.submit(1, play) == Authority.Result.MALFORMED, "run combat commands require an encounter ID")
	play.encounter_id = first.encounter_id
	_check(authority.submit(1, play) == Authority.Result.ACCEPTED, "an opening win enters the reward phase")
	var offer := authority.snapshot_for(1)
	var ally_offer := authority.snapshot_for(20)
	_check(offer.run_stage == "reward" and offer.run_revision == 1 and offer.reward_ready == 0 and
		offer.reward_options.size() == 1 and offer.reward_options[0].id == "shieldstrike",
		"the shared eligibility rule removes Universal and duplicate candidates")
	var take := _reward_request(offer, 2, "shieldstrike")
	_check(authority.submit(20, take) == Authority.Result.WRONG_PLAYER, "a peer cannot accept another player's reward")
	_check(authority.submit(20, _reward_request(ally_offer, 1, "test_universal")) == Authority.Result.ILLEGAL_ACTION,
		"a Universal card cannot be added through a forged reward choice")
	_check(authority.submit(1, take) == Authority.Result.ACCEPTED and authority.submit(1, take) == Authority.Result.DUPLICATE,
		"a valid reward sequence grants a single copy")
	_check(authority.submit(1, _reward_request(offer, 3, "shieldstrike")) == Authority.Result.ILLEGAL_ACTION,
		"a new sequence cannot submit a second reward")
	var waiting := authority.snapshot_for(1)
	var ally := authority.snapshot_for(20)
	_check(waiting.run_stage == "reward" and waiting.reward_ready == 1 and waiting.reward_submitted and
		waiting.reward_options.is_empty() and waiting.run_deck_count == 2 and not ally.reward_submitted and
		ally.run_deck_count == 1 and ally.reward_options.size() == 1 and waiting.players == ally.players,
		"the boss waits for all seats and projections keep each seat's choices and deck changes private")
	_check(authority.submit(20, _reward_request(ally, 2, "")) == Authority.Result.ACCEPTED, "skip completes the reward phase")
	var boss := authority.snapshot_for(1)
	var boss_ally := authority.snapshot_for(20)
	_check(boss.run_stage == "boss" and boss.encounter_id == 2 and boss.revision == 0 and boss.run_revision == 3,
		"encounter-local revision resets while run ordering continues")
	_check(_card(boss, "shieldstrike") >= 0 and _card(boss_ally, "shieldstrike") == -1 and not boss.has("reward_options"),
		"only the selecting player's deck changes and private offers are cleared")
	_check(_card(boss_ally, "basic_strike") == 0,
		"another seat's extra card does not shift the viewer's wire copy IDs")
	var late := _end_request(boss, 4)
	late.encounter_id = 1
	_check(authority.submit(1, late) == Authority.Result.STALE_TURN and authority.snapshot_for(1) == boss,
		"an earlier encounter's command cannot mutate the fresh boss even with current round and phase")
	var replayed_reward := _reward_request(boss, 2, "shieldstrike")
	_check(authority.submit(1, replayed_reward) == Authority.Result.DUPLICATE,
		"per-peer command sequencing survives the encounter transition")
	var own_card := _play_request(boss_ally, 3, 0)
	own_card.encounter_id = boss_ally.encounter_id
	_check(authority.submit(20, own_card) == Authority.Result.ACCEPTED and authority.snapshot_for(20).hand.is_empty(),
		"the host resolves a seat-local wire copy against its owner's actual boss hand")


func _reward_request(snapshot: Dictionary, sequence: int, card_id: String) -> Dictionary:
	return {"actor": snapshot.viewer, "sequence": sequence, "encounter_id": snapshot.encounter_id,
		"kind": int(Authority.Command.REWARD), "reward_id": card_id}


func _rune_encounter() -> EncounterData:
	var encounter: EncounterData = DATA.duplicate()
	encounter.test_deck = [STRIKE]
	encounter.enemy_max_hp = 60
	return encounter


func _cast_request(view: Dictionary, sequence: int, payload: Variant = null) -> Dictionary:
	var request := _end_request(view, sequence)
	request.kind = Authority.Command.CANCEL_CAST if payload == null else Authority.Command.SUBMIT_CAST
	request.token = view.cast.token
	if payload != null:
		request.strokes = payload
	if view.has("encounter_id"):
		request.encounter_id = view.encounter_id
	return request


func _begin_strike(authority: Authority, peer: int, sequence: int, now := NOW) -> Dictionary:
	var view := authority.snapshot_for(peer, now)
	var request := _play_request(view, sequence, _card(view, "basic_strike"))
	if view.has("encounter_id"):
		request.encounter_id = view.encounter_id
	_check(authority.submit(peer, request, now) == Authority.Result.ACCEPTED, "host begins an owned Strike")
	return authority.snapshot_for(peer, now)


func _test_network_cast_quality() -> void:
	var guide: PackedVector2Array = STRIKE.rune_template.strokes[0]
	var partial: Array[PackedVector2Array] = [PackedVector2Array([guide[0], guide[1], guide[1].lerp(guide[2], 0.57)])]
	var ordinary: Array[PackedVector2Array] = [PackedVector2Array([Vector2(0.33, 0.18), Vector2(0.50, 0.34),
		Vector2(0.58, 0.43), Vector2(0.62, 0.56), Vector2(0.48, 0.66), Vector2(0.32, 0.75)])]
	var cases := [[partial, "Faint", 75], [ordinary, "Acceptable", 100],
		[STRIKE.rune_template.strokes, "Excellent", 110]]
	for row in cases:
		var authority := Authority.new(_rune_encounter(), ASSIGNMENTS, null, null, SETTINGS)
		var view := _begin_strike(authority, 20, 1)
		_check(view.cast.remaining_ms == STRIKE.rune_template.cast_time_ms and view.revision == 0,
			"admission exposes the authoritative duration without spending or progressing combat")
		var request := _cast_request(view, 2, StrokePayload.encode(row[0]))
		var receipt := NOW + STRIKE.rune_template.cast_time_ms + Authority.RECEIVE_ALLOWANCE_MS - 1
		_check(authority.submit(20, request, receipt) == Authority.Result.ACCEPTED, "admit ink inside the host receipt window")
		var feedback := authority.take_cast_feedback(20)
		var after := authority.snapshot_for(20, receipt)
		_check(feedback.get("quality") == row[1] and feedback.get("power_percent") == row[2]
			and authority.take_cast_feedback(1).is_empty(), "host scores %s from raw ink and privately confirms it" % row[1])
		_check(after.players[1].mana == 2 and not after.has("cast") and after.revision == 1
			and _card(after, "basic_strike") == -1, "exactly one owned card and its Mana were consumed")
		_check(authority.submit(20, request, receipt) == Authority.Result.DUPLICATE, "deny duplicate sequence")
		request.sequence += 1
		_check(authority.submit(20, request, receipt) == Authority.Result.ILLEGAL_ACTION
			and authority.snapshot_for(20, receipt) == after, "deny a spent token with a fresh sequence")


func _test_network_cast_validation() -> void:
	var authority := Authority.new(_rune_encounter(), ASSIGNMENTS, null, null, SETTINGS)
	var view := authority.snapshot_for(20, NOW)
	var host := authority.snapshot_for(1, NOW)
	var play := _play_request(view, 1, _card(host, "basic_strike"))
	_check(authority.submit(20, play, NOW) == Authority.Result.ILLEGAL_ACTION, "deny another seat's card copy")
	play = _play_request(view, 2, _card(view, "basic_strike"))
	play.target = "absent"
	_check(authority.submit(20, play, NOW) == Authority.Result.ILLEGAL_ACTION, "deny nonexistent enemy")
	view = _begin_strike(authority, 20, 3)
	_check(not authority.snapshot_for(1, NOW).has("cast"), "only the owner gets the pending cast")
	host = _begin_strike(authority, 1, 1)
	var ink := StrokePayload.encode(STRIKE.rune_template.strokes)
	var submit := _cast_request(view, 4, ink)
	_check(authority.submit(1, submit, NOW) == Authority.Result.WRONG_PLAYER, "actor must match the sending seat")
	submit.actor = host.viewer
	submit.sequence = 2
	_check(authority.submit(1, submit, NOW) == Authority.Result.ILLEGAL_ACTION
		and authority.has_pending_cast(1) and authority.has_pending_cast(20), "a different seat's token leaves both casts intact")
	_check(authority.submit(1, _end_request(host, 3), NOW) == Authority.Result.ILLEGAL_ACTION,
		"cannot Ready while one's own cast is pending")
	_check(authority.submit(1, _cast_request(host, 4), NOW) == Authority.Result.ACCEPTED
		and authority.take_cast_feedback(1).get("status") == "canceled" and authority.has_pending_cast(20),
		"cancel releases only the caster's reservation without spending")
	var malformed := _cast_request(view, 4, ink)
	malformed.timestamp = INF
	_check(authority.submit(20, malformed, NOW) == Authority.Result.MALFORMED, "the wire shape has no client clock field")
	malformed.erase("timestamp")
	malformed.power_percent = 10000
	_check(authority.submit(20, malformed, NOW) == Authority.Result.MALFORMED, "the wire shape has no client power field")
	var oversize := PackedByteArray()
	oversize.resize(StrokePayload.MAX_BYTES + 1)
	_check(authority.submit(20, _cast_request(view, 4, oversize), NOW) == Authority.Result.MALFORMED,
		"limit incoming ink bytes before parsing strokes")
	_check(StrokePayload.decode(PackedByteArray([9])) == null
		and StrokePayload.decode(PackedByteArray([1, 0, 0])) == null
		and StrokePayload.decode(ink.slice(0, -1)) == null, "reject surplus strokes, empty segments, and truncated ink")
	var nonfinite := ink.duplicate()
	nonfinite.encode_float(3, NAN)
	_check(authority.submit(20, _cast_request(view, 4, nonfinite), NOW) == Authority.Result.MALFORMED
		and authority.take_cast_feedback(20).get("status") == "invalid" and not authority.has_pending_cast(20),
		"nonfinite input closes only its own attempt safely")
	var empty: Array[PackedVector2Array] = []
	view = _begin_strike(authority, 20, 5)
	_check(authority.submit(20, _cast_request(view, 6, StrokePayload.encode(empty)), NOW + 1)
		== Authority.Result.ILLEGAL_ACTION and authority.take_cast_feedback(20).get("status") == "misdrawn",
		"empty ink cannot resolve")
	view = _begin_strike(authority, 20, 7)
	var cutoff := NOW + STRIKE.rune_template.cast_time_ms + Authority.RECEIVE_ALLOWANCE_MS
	_check(authority.submit(20, _cast_request(view, 8, ink), cutoff) == Authority.Result.ILLEGAL_ACTION
		and authority.take_cast_feedback(20).get("status") == "expired", "reject even perfect ink at the receipt cutoff")
	_begin_strike(authority, 20, 9, cutoff)
	_check(authority.expire_casts(cutoff * 2) == [20] and authority.take_cast_feedback(20).get("status") == "expired",
		"expire a silent client without receiving its ink")
	_check(authority.snapshot_for(20).players[1].mana == 3 and authority.snapshot_for(20).revision == 0,
		"rejected and canceled attempts have no combat effects")


func _test_network_cast_run_cleanup() -> void:
	var run: RunData = RUN.duplicate()
	var encounter := _rune_encounter()
	encounter.enemy_max_hp = 6
	run.opening_encounters = [encounter]
	run.boss_encounter = encounter
	run.starting_deck = [STRIKE]
	var authority := Authority.new(encounter, ASSIGNMENTS, run, null, SETTINGS)
	var host := _begin_strike(authority, 1, 1)
	var client := _begin_strike(authority, 20, 1)
	var ink := StrokePayload.encode(STRIKE.rune_template.strokes)
	_check(authority.submit(1, _cast_request(host, 2, ink), NOW + 1) == Authority.Result.ACCEPTED,
		"first accepted drawn Strike enters the reward stage")
	var reward := authority.snapshot_for(20)
	_check(reward.run_stage == "reward" and not reward.has("cast") and reward.players[1].mana == 3
		and authority.take_cast_feedback(20).get("status") == "invalid",
		"a teammate's win cancels pending ink before publishing rewards")
	_check(authority.submit(1, _reward_request(reward.merged({"viewer": host.viewer}, true), 3, ""))
		== Authority.Result.ACCEPTED and authority.submit(20, _reward_request(reward, 2, "")) == Authority.Result.ACCEPTED,
		"private reward skips advance the run")
	var boss := _begin_strike(authority, 20, 3)
	var stale := _cast_request(client, 4, ink)
	_check(boss.encounter_id == 2 and authority.submit(20, stale, NOW) == Authority.Result.STALE_TURN,
		"the same round number cannot make an old-encounter cast current")
	stale.sequence += 1
	stale.encounter_id = boss.encounter_id
	_check(authority.submit(20, stale, NOW) == Authority.Result.ILLEGAL_ACTION and authority.has_pending_cast(20),
		"even with a current encounter ID the old token cannot resolve the new cast")
	_check(authority.submit(20, _cast_request(boss, 6, ink), NOW + 1) == Authority.Result.ACCEPTED
		and authority.snapshot_for(1).run_stage == "victory" and not authority.has_pending_cast(20),
		"a drawn boss finisher clears the token and publishes run victory")


func _test_network_cast_target_and_defeat() -> void:
	var encounter: EncounterData = TWO_SLIMES.duplicate()
	encounter.enemies = TWO_SLIMES.enemies.duplicate()
	encounter.enemies[0] = encounter.enemies[0].duplicate()
	encounter.enemies[0].max_hp = 6
	encounter.test_deck = [STRIKE]
	var authority := Authority.new(encounter, ASSIGNMENTS, null, null, SETTINGS)
	var first := _begin_strike(authority, 1, 1)
	var other := _begin_strike(authority, 20, 1)
	var ink := StrokePayload.encode(STRIKE.rune_template.strokes)
	_check(authority.submit(1, _cast_request(first, 2, ink), NOW + 1) == Authority.Result.ACCEPTED,
		"one completed cast defeats the selected enemy")
	var after := authority.snapshot_for(20)
	_check(after.phase == CombatState.Phase.PLAYER and not after.enemies[0].alive and after.enemies[1].hp == 22
		and not after.has("cast") and authority.take_cast_feedback(20).get("status") == "invalid",
		"the other cast closes if its exact target dies mid-phase, and never transfers to a living foe")
	_check(authority.submit(20, _cast_request(other, 2, ink), NOW + 2) == Authority.Result.ILLEGAL_ACTION
		and authority.snapshot_for(20).players[1].mana == 3, "late ink for a defeated target cannot consume Mana")

	encounter = _rune_encounter()
	encounter.player_max_hp = 1
	encounter.enemy_attack = 3
	authority = Authority.new(encounter, ASSIGNMENTS, null, null, SETTINGS)
	first = _begin_strike(authority, 1, 1)
	_check(authority.submit(20, _end_request(authority.snapshot_for(20), 1), NOW) == Authority.Result.ACCEPTED
		and authority.submit(1, _end_request(first, 2), NOW) == Authority.Result.ILLEGAL_ACTION,
		"waiting on an open cast does not block a different seat from becoming Ready")
	_check(authority.submit(1, _cast_request(first, 3), NOW) == Authority.Result.ACCEPTED
		and authority.submit(1, _end_request(first, 4), NOW) == Authority.Result.ACCEPTED,
		"the caster can cancel and close the phase")
	var defeat := authority.snapshot_for(1)
	_check(defeat.phase == CombatState.Phase.DEFEAT and not defeat.has("cast") and not authority.has_pending_cast(20)
		and authority.submit(1, _cast_request(first, 5, ink), NOW + 1) == Authority.Result.STALE_TURN,
		"party defeat leaves no active casting state and rejects an old cast")


func _test_network_booster_fallback() -> void:
	var authority := Authority.new(_rune_encounter(), ASSIGNMENTS, null, null, SETTINGS)
	var view := authority.snapshot_for(20, NOW)
	_check(authority.submit(20, _play_request(view, 1, _card(view, "spell_ink_booster")), NOW)
		== Authority.Result.ACCEPTED and authority.snapshot_for(20).booster_primed
		and not authority.snapshot_for(1).booster_primed and not authority.has_pending_cast(20),
		"the Booster resolves instantly for its owner only")
	view = _begin_strike(authority, 20, 2)
	_check(view.cast.boosted and authority.submit(20, _cast_request(view, 3), NOW) == Authority.Result.ACCEPTED
		and authority.snapshot_for(20).booster_primed, "cancel keeps the pending Booster charge")
	view = _begin_strike(authority, 20, 4)
	var base_ink := StrokePayload.encode(STRIKE.rune_template.strokes)
	_check(authority.submit(20, _cast_request(view, 5, base_ink), NOW + 1) == Authority.Result.ACCEPTED
		and authority.take_cast_feedback(20).get("power_percent") == 75
		and not authority.snapshot_for(20).booster_primed,
		"base-only recognition resolves at reduced power and consumes the Booster")


func _play_request(snapshot: Dictionary, sequence: int, copy: int) -> Dictionary:
	var request := {"actor": snapshot.viewer, "sequence": sequence, "round": snapshot.round, "phase": snapshot.phase,
		"ready_epoch": snapshot.ready_epoch,
		"kind": int(Authority.Command.PLAY_CARD), "copy": copy}
	for card in snapshot.hand:
		if card.copy == copy and card.targets_enemy:
			request["target"] = snapshot.enemies[0].id
			break
	return request


func _end_request(snapshot: Dictionary, sequence: int) -> Dictionary:
	return {"actor": snapshot.viewer, "sequence": sequence, "round": snapshot.round, "phase": snapshot.phase,
		"ready_epoch": snapshot.ready_epoch,
		"kind": int(Authority.Command.END_TURN)}


func _check(condition: bool, context: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(context)
