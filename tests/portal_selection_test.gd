extends SceneTree

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const PortalRoute = preload("res://scripts/run/portal_route.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const RunState = preload("res://scripts/run/run_state.gd")
const ROUTE = preload("res://resources/prototype/multi_enemy_run.tres")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")

var _checks := 0
var _failures := 0
var _sequences: Dictionary[int, int] = {}


func _initialize() -> void:
	_test_graph()
	_test_drawing()
	_test_solo()
	for size in [2, 3, 4]:
		_test_authority(size)
	print("Portal selection: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _test_graph() -> void:
	var paths := {}
	var stable_ids := {}
	for seed in [11, 47, 42017, 104774, 918273]:
		var graph := PortalRoute.new(seed)
		var replay := PortalRoute.new(seed)
		var opening := graph.options(PortalRoute.START)
		_check(opening.size() == 2 and opening == replay.options(PortalRoute.START),
			"same seed replays two opening options and their previews")
		_check(graph.options(PortalRoute.BOSS).is_empty() and graph.options(&"unknown").is_empty()
			and graph.destination(PortalRoute.START, &"invalid") == null,
			"the graph terminates at the boss and rejects unknown edges")
		paths[JSON.stringify(opening)] = true
		var first_ids := {}
		for portal in opening:
			var link := StringName(portal.id)
			var encounter := graph.destination(PortalRoute.START, link)
			var destination := encounter.enemy_id
			_check(destination in [&"goblin_treant", &"three_enemies"] and not first_ids.has(destination)
				and encounter != null and encounter.enemy_id == destination
				and portal.type == "Normal Encounter" and portal.size() == 3
				and String(link).length() == 64 and String(link).is_valid_hex_number(),
				"opening portals point to existing encounters and expose only category, opaque token, and branches")
			first_ids[destination] = true
			_verify_stable_id(stable_ids, PortalRoute.START, destination, portal)
			var next := graph.options(destination)
			_check(next.size() == 2 and next == replay.options(destination)
				and portal.branches == _preview_of(next), "an opening preview lists both immediate next branches")
			var next_ids := {}
			for branch in next:
				var next_destination := graph.destination(destination, StringName(branch.id)).enemy_id
				_check(next_destination in [&"slime", &"goblin", &"treant"] and not next_ids.has(next_destination),
					"later branches have distinct supported destinations")
				next_ids[next_destination] = true
				_verify_stable_id(stable_ids, destination, next_destination, branch)
				var finals := graph.options(next_destination)
				_check(finals.size() == 1 and finals[0].type == "Boss Encounter"
					and finals[0].branches.is_empty() and branch.branches == _preview_of(finals),
					"each later branch previews one terminal boss portal")
				if finals.size() == 1:
					var boss := graph.destination(next_destination, StringName(finals[0].id))
					_check(boss != null and boss.enemy_id == PortalRoute.BOSS and boss.enemies.size() <= 1,
						"the only final destination is the existing single-enemy boss")
	_check(paths.size() > 1, "different seeds vary the presented branching graph")
	_check(PortalRoute.category_label(EncounterData.Category.ELITE) == "Elite Encounter",
		"explicit elite metadata has an elite preview label")


func _verify_stable_id(ids: Dictionary, source: StringName, target: StringName, portal: Dictionary) -> void:
	var key := "%s:%s" % [source, target]
	_check(not String(portal.id).is_empty() and ids.get(key, portal.id) == portal.id,
		"the same source and destination have a stable portal ID across seeds")
	ids[key] = portal.id


func _preview_of(options: Array[Dictionary]) -> Array[Dictionary]:
	var preview: Array[Dictionary] = []
	for option in options:
		preview.append({"type": option.type})
	return preview


func _test_drawing() -> void:
	const SAMPLES := 300
	for seats in [2, 3, 4]:
		var first_wins := 0
		var valid := true
		var replayed := true
		for seed in SAMPLES:
			var graph := PortalRoute.new(seed)
			var opening := graph.options(PortalRoute.START)
			var first := StringName(opening[0].id)
			var second := StringName(opening[1].id)
			var choices: Array[StringName] = []
			for seat in seats:
				choices.append(second if seat == seats - 1 else first)
			var winner := graph.resolve(choices)
			valid = valid and winner in [first, second]
			replayed = replayed and winner == PortalRoute.new(seed).resolve(choices)
			first_wins += int(winner == first)
		var fraction := float(first_wins) / SAMPLES
		var expected := float(seats - 1) / float(seats)
		_check(valid and replayed, "%d-seat draw selects a submitted entry and replays exactly" % seats)
		_check(absf(fraction - expected) < 0.10,
			"%d-seat draw is weighted per vote across %d seeds, got %d first choices" % [seats, SAMPLES, first_wins])
		print("Portal draw %d seats: %d/%d first choice." % [seats, first_wins, SAMPLES])


func _test_solo() -> void:
	var data := _fixture()
	var baseline: RunData = ROUTE.duplicate()
	baseline.starting_deck = [STRIKE, STRIKE, STRIKE, STRIKE, STRIKE]
	var ordinary := RunState.new(baseline)
	_check(ordinary.choose_opening(PortalRoute.START), "the non-portal fixture still starts")
	_win_solo(ordinary)
	_check(ordinary.skip_reward() and ordinary.start_next_encounter()
		and ordinary.active_encounter.enemy_id == &"goblin_treant",
		"non-portal paths keep their automatic fixed destination")
	var run := RunState.new(data)
	var chosen := StringName(run.arcana_options()[0].id)
	_check(run.submit_arcana(chosen) and run.choose_opening(PortalRoute.START), "Arcana selection still precedes solo combat")
	_check(not run.submit_portal(&"invalid") and run.portal_options().is_empty(), "combat exposes no selectable portals")
	for encounter_id in range(1, 5):
		var player := run.active_combat.players[RunState.PLAYER_ID]
		_check(run.encounter_id == encounter_id and player.arcana_id == chosen, "chosen Arcana carries into each fight")
		_win_solo(run)
		if encounter_id == 4:
			break
		_check(run.portal_options().is_empty() and not run.submit_portal(&"invalid"),
			"the reward must settle before portal selection")
		var deck_size := run.deck_cards().size()
		if encounter_id == 1:
			_check(run.take_reward(run.reward_options()[0].id) and run.deck_cards().size() == deck_size + 1,
				"a taken reward enters the persistent solo deck")
		else:
			_check(run.skip_reward() and run.deck_cards().size() == deck_size, "Skip leaves the deck alone")
		var options := run.portal_options()
		_check(run.stage == RunState.Stage.PORTAL and options.size() == (1 if encounter_id == 3 else 2)
			and not run.start_next_encounter() and not run.submit_portal(&"invalid"),
			"solo cannot bypass the portal gate or select an unoffered edge")
		var pick: Dictionary = options[-1]
		var expected_id := PortalRoute.new(data.run_seed).destination(run.active_encounter.enemy_id, StringName(pick.id)).enemy_id
		_check(run.submit_portal(StringName(pick.id)) and run.active_encounter.enemy_id == expected_id
			and not run.submit_portal(StringName(pick.id)) and run.current_hp == 24,
			"selecting a portal starts the selected fight once, with HP carried forward")
	_check(run.stage == RunState.Stage.VICTORY and run.portal_options().is_empty(), "victory ends the full portal route")
	var defeated := RunState.new(data)
	defeated.submit_arcana(&"")
	defeated.choose_opening(PortalRoute.START)
	var player := defeated.active_combat.players[RunState.PLAYER_ID]
	player.hp = 1
	player.burning = 1
	defeated.active_combat.end_turn(RunState.PLAYER_ID)
	_check(defeated.finish_combat(defeated.active_combat) and defeated.stage == RunState.Stage.DEFEAT
		and not defeated.submit_portal(&"invalid"), "defeat stays terminal without opening a portal")


func _win_solo(run: RunState) -> void:
	var fight := run.active_combat
	var player := fight.players[RunState.PLAYER_ID]
	player.hp = 24
	for enemy in fight.enemies:
		enemy.hp = 1
		var copy := _strike_copy(fight, RunState.PLAYER_ID)
		_check(fight.play_card(RunState.PLAYER_ID, copy, enemy.id), "play a selected strike in the solo fixture")
	_check(run.finish_combat(fight), "the run observes a finished encounter")


func _test_authority(size: int) -> void:
	_sequences.clear()
	var data := _fixture()
	var seats: Dictionary[int, StringName] = {}
	for peer in range(1, size + 1):
		seats[peer] = StringName("Battle Mage %d" % peer)
	var authority := Authority.new(data.opening_encounters[0], seats, data)
	var arcana: String = authority.snapshot_for(1).arcana_options[0].id
	for peer in seats:
		_send(authority, peer, Authority.Command.ARCANA, {"arcana_id": arcana if peer == 1 else ""})
	var replay := PortalRoute.new(data.run_seed)
	_send(authority, 1, Authority.Command.PORTAL, {"portal_id": "invalid"}, Authority.Result.ILLEGAL_ACTION)
	var last_portal: Dictionary
	for encounter_id in range(1, 5):
		var combat := authority.snapshot_for(1)
		var source_id := authority._run.active_encounter.enemy_id
		var ally := authority.snapshot_for(2)
		_check(combat.encounter_id == encounter_id and combat.arcana.id == arcana
			and not ally.has("arcana") and combat.players == ally.players and combat.enemies == ally.enemies
			and not combat.players[0].has("hand") and not combat.has("portal_options") and not combat.has("portal_votes"),
			"playthrough carries private Arcana and publishes a common combat state")
		if encounter_id > 1:
			_check(ally.players[1].hp == 9, "a recovered teammate's HP carries across portals")
		if encounter_id == 1:
			authority._state.players[seats[2]].hp = 0
		for enemy in authority._state.enemies:
			enemy.hp = 1
			var turn := authority.snapshot_for(1)
			var copy := _strike_copy(authority._state, seats[1])
			_send(authority, 1, Authority.Command.PLAY_CARD, {
				"copy": copy, "target": String(enemy.id), "round": turn.round, "phase": turn.phase,
				"ready_epoch": turn.ready_epoch,
			})
		if encounter_id == 4:
			break
		_check(authority.snapshot_for(1).run_stage == "reward", "a normal victory opens the existing reward gate")
		if not last_portal.is_empty():
			_send(authority, 1, Authority.Command.PORTAL, last_portal, Authority.Result.STALE_TURN)
		for peer in seats:
			var reward := authority.snapshot_for(peer)
			_check(reward.run_stage == "reward" and not reward.has("portal_options"),
				"portal choices stay closed while reward decisions are pending")
			_send(authority, peer, Authority.Command.REWARD,
				{"reward_id": reward.reward_options[0].id if peer == 1 and encounter_id == 1 else ""})
		var gate := authority.snapshot_for(1)
		var options: Array = gate.portal_options
		_check(gate.run_stage == "portal" and gate.encounter_id == encounter_id and gate.portal_ready == 0
			and options == authority.snapshot_for(2).portal_options
			and gate.portal_votes.is_empty() and not gate.has("reward_options") and gate.run_deck_count == data.starting_deck.size() + 1
			and authority.snapshot_for(2).run_deck_count == data.starting_deck.size(),
			"the party opens a shared portal gate after individual reward decisions")
		var first: Dictionary = options[0]
		var last: Dictionary = options[-1]
		if not last_portal.is_empty():
			_send(authority, 1, Authority.Command.PORTAL, {"portal_id": last_portal.portal_id}, Authority.Result.ILLEGAL_ACTION)
		last_portal = {"portal_id": first.id, "encounter_id": encounter_id}
		_send(authority, 1, Authority.Command.REWARD, {"reward_id": ""}, Authority.Result.ILLEGAL_ACTION)
		_send(authority, 2, Authority.Command.PORTAL, {"actor": gate.viewer, "portal_id": first.id},
			Authority.Result.WRONG_PLAYER)
		_send(authority, 2, Authority.Command.PORTAL, {"portal_id": 42}, Authority.Result.MALFORMED)
		_send(authority, 2, Authority.Command.PORTAL, {"portal_id": "unoffered"}, Authority.Result.ILLEGAL_ACTION)
		_send(authority, 1, Authority.Command.PORTAL, {"portal_id": first.id})
		var submitted := authority.snapshot_for(1)
		var waiting := authority.snapshot_for(2)
		_check(submitted.portal_submitted and submitted.portal_ready == 1 and submitted.encounter_id == encounter_id
			and not waiting.portal_submitted, "the host waits for the other seats and scopes submission status")
		_check(submitted.portal_votes == {submitted.viewer: first.id} and waiting.portal_votes == submitted.portal_votes,
			"the shared vote display maps a Mage only to their submitted opaque portal token")
		_send(authority, 1, Authority.Command.PORTAL, {"portal_id": first.id}, Authority.Result.DUPLICATE, true)
		_send(authority, 1, Authority.Command.PORTAL, {"portal_id": last.id}, Authority.Result.ILLEGAL_ACTION)
		var entries: Array[StringName] = [StringName(first.id)]
		for peer in range(2, size + 1):
			entries.append(StringName(last.id if peer == size else first.id))
		for peer in range(size, 1, -1):
			_send(authority, peer, Authority.Command.PORTAL, {"portal_id": String(entries[peer - 1])})
		var chosen := replay.resolve(entries)
		_check(authority._run.active_encounter.enemy_id == replay.destination(source_id, chosen).enemy_id
			and authority.snapshot_for(1).encounter_id == encounter_id + 1,
			"the host draw uses roster order with out-of-order votes, including the recovered teammate")
	_check(authority.snapshot_for(1).run_stage == "victory" and not authority.snapshot_for(1).has("portal_options"),
		"authority completes the route after defeating its one boss")


func _strike_copy(fight: CombatState, player_id: StringName) -> int:
	for copy in fight.players[player_id].hand:
		if fight.card_data(copy).id == STRIKE.id:
			return copy
	return -1


func _send(authority: Authority, peer: int, kind: Authority.Command, fields: Dictionary,
		expected := Authority.Result.ACCEPTED, replay := false) -> void:
	var before := authority.snapshot_for(peer)
	var sequence: int = _sequences.get(peer, 0) + int(not replay)
	_sequences[peer] = sequence
	var request := {"actor": before.viewer, "sequence": sequence, "kind": int(kind),
		"encounter_id": before.encounter_id}
	request.merge(fields, true)
	var actual := authority.submit(peer, request)
	_check(actual == expected and (expected == Authority.Result.ACCEPTED or authority.snapshot_for(peer) == before),
		"seat %d command %s expected %s, got %s" % [peer, Authority.Command.keys()[kind],
			Authority.Result.keys()[expected], Authority.Result.keys()[actual]])


func _fixture() -> RunData:
	var data: RunData = ROUTE.duplicate()
	data.portal_enabled = true
	data.major_arcana_enabled = true
	data.starting_deck = [STRIKE, STRIKE, STRIKE, STRIKE, STRIKE]
	return data


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
