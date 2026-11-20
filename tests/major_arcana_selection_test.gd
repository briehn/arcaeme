extends SceneTree

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const MajorArcana = preload("res://scripts/run/major_arcana.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const RunState = preload("res://scripts/run/run_state.gd")
const ROUTE = preload("res://resources/prototype/multi_enemy_run.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_check(not ROUTE.major_arcana_enabled and RunState.new(ROUTE).stage == RunState.Stage.ROUTE,
		"the production resource defaults to the Arcana-disabled route")
	_test_offers()
	_test_solo()
	for size in [2, 3, 4]:
		_test_authority(size)
	print("Major Arcana selection: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _test_offers() -> void:
	var layouts := {}
	for seed in [42017, 104774, 918273]:
		for seat in range(4):
			var offers := MajorArcana.offers(seed, seat, RunData.BATTLE_MAGE)
			var distinct := {}
			for option in offers:
				distinct[option] = true
				var description := MajorArcana.view(option)
				_check(not description.is_empty() and description.id == String(option)
					and not description.name.is_empty() and not description.description.is_empty(),
					"each offer is an identified, described Arcana")
			_check(offers.size() == 3 and distinct.size() == 3
				and offers == MajorArcana.offers(seed, seat, RunData.BATTLE_MAGE),
				"seed and seat replay three distinct offers")
			layouts[JSON.stringify(offers)] = true
	_check(layouts.size() > 1 and MajorArcana.offers(42017, 0, &"unimplemented_class").is_empty(),
		"offers vary across seeds and seats, and another class gets no Battle Mage offers")


func _test_solo() -> void:
	var data := _fixture()
	var run := RunState.new(data)
	var opening_id := data.opening_encounters[0].enemy_id
	var offers := run.arcana_options()
	_check(run.stage == RunState.Stage.ARCANA and run.active_combat == null and offers.size() == 3
		and offers == RunState.new(data).arcana_options() and not run.choose_opening(opening_id),
		"solo offers replay and gate first combat")
	offers.clear()
	_check(run.arcana_options().size() == 3 and not run.submit_arcana(&"unoffered"),
		"changing a projection or selecting an unoffered ID does not settle the choice")
	var chosen := StringName(run.arcana_options()[0].id)
	_check(run.submit_arcana(chosen) and run.selected_arcana == chosen
		and run.stage == RunState.Stage.ROUTE and run.arcana_options().is_empty()
		and not run.submit_arcana(&"") and run.choose_opening(opening_id),
		"one accepted option stays fixed when opening combat")
	var skip := RunState.new(data)
	_check(skip.submit_arcana(&"") and skip.selected_arcana == &"" and skip.choose_opening(opening_id),
		"solo Skip completes selection without a passive")
	var disabled_fixture: RunData = data.duplicate()
	disabled_fixture.major_arcana_enabled = false
	var disabled := RunState.new(disabled_fixture)
	_check(disabled.choose_opening(opening_id)
		and disabled.active_combat.players[RunState.PLAYER_ID].hand == skip.active_combat.players[RunState.PLAYER_ID].hand,
		"Arcana offer generation preserves the original seeded opening hand when skipped")
	skip.active_combat.players[RunState.PLAYER_ID].hp = 1
	skip.active_combat.players[RunState.PLAYER_ID].burning = 1
	skip.active_combat.end_turn(RunState.PLAYER_ID)
	_check(skip.finish_combat(skip.active_combat) and skip.stage == RunState.Stage.DEFEAT
		and not skip.submit_arcana(chosen), "defeat remains terminal after skipping")


func _test_authority(size: int) -> void:
	var data := _fixture()
	var seats: Dictionary[int, StringName] = {}
	for peer in range(1, size + 1):
		seats[peer] = StringName("Battle Mage %d" % peer)
	var authority := Authority.new(data.opening_encounters[0], seats, data)
	var first := authority.snapshot_for(1)
	var second := authority.snapshot_for(2)
	var first_id: String = first.arcana_options[0].id
	_check(first.encounter_id == 0 and first.run_revision == 0 and first.arcana_ready == 0
		and second.arcana_ready == 0 and first.arcana_options.size() == 3 and second.arcana_options.size() == 3
		and not _has_combat(first) and not _has_combat(second), "%d seats begin behind a private selection gate" % size)
	_reject(authority, 2, _pick(first, 1, first_id), Authority.Result.WRONG_PLAYER, "a peer cannot choose for another Mage")
	_reject(authority, 99, _pick(first, 1, first_id), Authority.Result.UNKNOWN_PEER, "a nonmember cannot choose")
	_reject(authority, 1, _pick(first, 1, 42), Authority.Result.MALFORMED, "an Arcana ID must be a string")
	_reject(authority, 1, _pick(first, 1, "unoffered"), Authority.Result.ILLEGAL_ACTION, "reject a fabricated offer")
	_reject(authority, 1, {"actor": first.viewer, "sequence": 2, "kind": int(Authority.Command.REWARD),
		"encounter_id": 1, "reward_id": ""}, Authority.Result.STALE_TURN, "precombat cannot accept a reward from a future encounter")
	_reject(authority, 1, {"actor": first.viewer, "sequence": 3, "kind": int(Authority.Command.END_TURN),
		"encounter_id": 1, "round": 1, "phase": int(CombatState.Phase.PLAYER), "ready_epoch": 0},
		Authority.Result.STALE_TURN, "precombat cannot accept Ready")
	var valid := _pick(first, 4, first_id)
	_check(authority.submit(1, valid) == Authority.Result.ACCEPTED, "owner may select an offered option")
	_reject(authority, 1, valid, Authority.Result.DUPLICATE, "retry cannot double-select")
	_reject(authority, 1, _pick(first, 5, ""), Authority.Result.ILLEGAL_ACTION, "a newer sequence cannot change a locked choice")
	var waiting := authority.snapshot_for(1)
	_check(waiting.arcana_submitted and waiting.arcana_options.is_empty() and waiting.arcana_ready == 1
		and not _has_combat(waiting) and authority.snapshot_for(2).arcana_options == second.arcana_options,
		"selection hides settled offers and leaves another seat's original offers intact")
	for peer in range(2, size + 1):
		_check(authority.submit(peer, _pick(authority.snapshot_for(peer), 1, "")) == Authority.Result.ACCEPTED,
			"other seat may independently skip")
		if peer < size:
			_check(not _has_combat(authority.snapshot_for(peer)), "combat waits for the final participating seat")
	_reject(authority, 1, _pick(first, 6, ""), Authority.Result.STALE_TURN, "late opening selection cannot modify active combat")
	var sequence := 6
	for encounter_id in range(1, 4):
		var combat := authority.snapshot_for(1)
		var ally := authority.snapshot_for(2)
		_check(combat.encounter_id == encounter_id and combat.get("arcana", {}).get("id") == first_id
			and ally.get("arcana", {}).is_empty() and combat.players == ally.players
			and combat.enemies == ally.enemies and not combat.has("arcana_options") and not ally.has("arcana_options"),
			"persistent Arcana and Skip remain viewer-private across encounter boundaries")
		for enemy in combat.enemies:
			sequence += 1
			var turn := authority.snapshot_for(1)
			var copy: int = turn.hand[0].copy
			_check(authority.submit(1, {"actor": first.viewer, "sequence": sequence,
				"kind": int(Authority.Command.PLAY_CARD), "encounter_id": encounter_id, "round": turn.round,
				"phase": turn.phase, "ready_epoch": turn.ready_epoch, "copy": copy, "target": enemy.id})
				== Authority.Result.ACCEPTED, "host accepts the owner’s targeted strike")
		if encounter_id < 3:
			_check(authority.snapshot_for(1).run_stage == "reward", "completed normal combat opens its card reward")
			for peer in range(1, size + 1):
				if peer == 1:
					sequence += 1
				_check(authority.submit(peer, {"actor": authority.snapshot_for(peer).viewer,
					"sequence": sequence if peer == 1 else encounter_id + 1, "kind": int(Authority.Command.REWARD),
					"encounter_id": encounter_id, "reward_id": ""}) == Authority.Result.ACCEPTED,
					"Arcana selection leaves each reward decision available")
	_check(authority.snapshot_for(1).run_stage == "victory", "the final boss ends the enabled run")


func _has_combat(view: Dictionary) -> bool:
	return view.has("hand") or view.has("players") or view.has("enemies") or view.has("reward_options")


func _pick(view: Dictionary, sequence: int, id: Variant) -> Dictionary:
	return {"actor": view.viewer, "sequence": sequence, "kind": int(Authority.Command.ARCANA),
		"encounter_id": 0, "arcana_id": id}


func _reject(authority: Authority, peer: int, request: Dictionary, expected: Authority.Result, label: String) -> void:
	var before := authority.snapshot_for(peer)
	_check(authority.submit(peer, request) == expected and authority.snapshot_for(peer) == before, label)


func _fixture() -> RunData:
	var data: RunData = ROUTE.duplicate()
	data.major_arcana_enabled = true
	data.starting_deck = [STRIKE, STRIKE, STRIKE, STRIKE, STRIKE]
	data.opening_encounters = [_one_hp(data.opening_encounters[0])]
	data.intermediate_encounters = [_one_hp(data.intermediate_encounters[0])]
	data.boss_encounter = _one_hp(data.boss_encounter)
	return data


func _one_hp(template: EncounterData) -> EncounterData:
	var encounter: EncounterData = template.duplicate()
	encounter.enemy_max_hp = 1
	encounter.enemies = template.enemies.duplicate()
	for index in encounter.enemies.size():
		encounter.enemies[index] = template.enemies[index].duplicate()
		encounter.enemies[index].max_hp = 1
	return encounter


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
