extends SceneTree

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const DATA = preload("res://resources/prototype/local_coop_encounter.tres")
const ASSIGNMENTS: Dictionary[int, StringName] = {1: &"Battle Mage 1", 20: &"Battle Mage 2"}

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_authority_and_privacy()
	_test_waiting_staleness_and_replay()
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


func _play_request(snapshot: Dictionary, sequence: int, copy: int) -> Dictionary:
	return {"actor": snapshot.viewer, "sequence": sequence, "round": snapshot.round, "phase": snapshot.phase,
		"kind": int(Authority.Command.PLAY_CARD), "copy": copy}


func _end_request(snapshot: Dictionary, sequence: int) -> Dictionary:
	return {"actor": snapshot.viewer, "sequence": sequence, "round": snapshot.round, "phase": snapshot.phase,
		"kind": int(Authority.Command.END_TURN)}


func _check(condition: bool, context: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(context)
