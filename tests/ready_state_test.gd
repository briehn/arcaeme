extends SceneTree

const Authority = preload("res://scripts/network/network_combat_authority.gd")
const CardData = preload("res://scripts/combat/card_data.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const TWO_SLIMES = preload("res://resources/prototype/enemies/two_slimes.tres")
const WARDED_STRIKE = preload("res://resources/prototype/cards/expansion/warded_strike.tres")
const MAGE := &"Battle Mage 1"
const ALLY := &"Battle Mage 2"
const THIRD := &"Battle Mage 3"
const FIRST_SLIME := &"slime_1"
const SECOND_SLIME := &"slime_2"
const DECK: Array[CardData] = [WARDED_STRIKE, WARDED_STRIKE, WARDED_STRIKE, WARDED_STRIKE, WARDED_STRIKE]

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_reversible_readiness_preserves_private_turn()
	_finalization_handles_defeated_mages()
	_lethal_card_wins_during_open_phase()
	_solo_finishes_immediately()
	_host_validates_round_ready_epoch_and_target()
	_sole_target_is_explicit_on_the_wire()
	print("Ready state: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _reversible_readiness_preserves_private_turn() -> void:
	var state := _combat([MAGE, ALLY])
	var player := state.players[MAGE]
	var card := player.hand[0]
	_check(state.play_card(MAGE, card, SECOND_SLIME), "first legal card resolves before ready")
	_check(player.discard_pile == [card], "played card is discarded immediately after resolution")
	player.poison = 2
	player.burning = 5
	player.next_attack_bonus = 6
	var original := _resources(player)
	for index in 2:
		_check(state.end_turn(MAGE), "player may mark Ready while their ally is unready")
		_check(state.phase == CombatState.Phase.PLAYER and state.round_number == 1
			and player.ended_turn and player.ready_epoch == index * 2 + 1,
			"Ready changes only eligibility during the open phase")
		_check(state.can_undo_ready(MAGE) and not state.can_undo_ready(ALLY)
			and not state.can_end_turn(MAGE) and not state.can_play_card(MAGE, player.hand[0], SECOND_SLIME),
			"only a living ready player can undo, and Ready disables cards")
		var revision := state.action_history.size()
		_check(not state.end_turn(MAGE) and not state.undo_ready(ALLY)
			and state.action_history.size() == revision, "invalid duplicate transitions do not enter history")
		_check(_resources(player) == original and _event_count(state, "discarded ") == 0
			and _event_count(state, " HP to ") == 0 and _event_count(state, "shuffled ") == 0,
			"waiting preserves hand, piles, Mana, Block, statuses, and preparation")
		_check(state.undo_ready(MAGE) and not player.ended_turn and player.ready_epoch == index * 2 + 2,
			"undo restores active status and advances the readiness epoch")
		_check(_resources(player) == original and state.can_play_card(MAGE, player.hand[0], SECOND_SLIME),
			"undo restores the same playable hand without refreshing turn resources")
	_check(state.play_card(MAGE, player.hand[0], SECOND_SLIME) and player.block == 8,
		"retained card is playable after undo and preserves existing Block")
	_check(state.end_turn(MAGE) and state.end_turn(ALLY), "last living player finalizes the shared phase")
	_check(state.round_number == 2 and state.phase == CombatState.Phase.PLAYER
		and not player.ended_turn and not state.can_undo_ready(MAGE),
		"following player phase opens with readiness reset and no pending undo")
	_check(player.hp == 29 and player.poison == 1 and player.burning == 3 and player.block == 0,
		"Burning and Poison tick once each and remaining Block expires at next turn start")
	_check(player.next_attack_bonus == 0 and player.mana == CombatState.TURN_MANA
		and player.hand.size() == CombatState.TURN_DRAW and player.discard_pile.is_empty(),
		"preparation expires and all unplayed cards can re-enter an exhausted draw pile only at closure")
	_check(_event_count(state, "discarded ") == 2 and _event_count(state, "shuffled ") == 2
		and _event_count(state, "Battle Mage 1 drew ") == 2
		and _event_count(state, "Battle Mage 1 lost 5 HP to Burning.") == 1
		and _event_count(state, "Battle Mage 1 lost 2 HP to Poison.") == 1,
		"each turn boundary effect runs exactly once per applicable Mage")
	_check(state.enemies[0].action_index == 1 and state.enemies[1].action_index == 1
		and state.players[ALLY].hp == 29,
		"both enemies act once and deal full announced damage against the unblocked Mage")


func _finalization_handles_defeated_mages() -> void:
	var starting_hp: Dictionary[StringName, int] = {THIRD: 0}
	var state := _combat([MAGE, ALLY, THIRD], starting_hp)
	var doomed := state.players[ALLY]
	doomed.hp = 1
	doomed.burning = 3
	_check(not state.can_end_turn(THIRD) and not state.end_turn(THIRD) and not state.undo_ready(THIRD),
		"already defeated Mage cannot ready or undo")
	_check(state.end_turn(ALLY) and doomed.hp == 1 and doomed.burning == 3,
		"lethal Burning is deferred while a living teammate remains active")
	_check(state.end_turn(MAGE) and state.round_number == 2 and doomed.hp == 0,
		"existing defeated seat cannot block phase finalization; Burning can defeat another during closure")
	_check(doomed.hand.is_empty() and doomed.discard_pile.size() == DECK.size()
		and state.players[THIRD].hand.is_empty(), "phase cleanup discards only the applicable living hands")
	_check(state.players[MAGE].hp == 29 and _event_count(state, "Battle Mage 2 blocked ") == 0,
		"enemies attack the survivor and skip Mages defeated before enemy actions")
	_check(state.end_turn(MAGE) and state.round_number == 3 and state.enemies[0].action_index == 2,
		"the sole surviving Mage immediately closes their next phase")

	var wipe := _combat([MAGE, ALLY])
	for player in wipe.players.values():
		player.hp = 1
		player.burning = 3
	_check(wipe.end_turn(MAGE) and wipe.end_turn(ALLY) and wipe.phase == CombatState.Phase.DEFEAT,
		"lethal player Burning finalizes all personal turns and ends the fight")
	_check(wipe.enemies[0].action_index == 0 and wipe.enemies[1].action_index == 0
		and _event_count(wipe, "lost 1 HP to Burning.") == 2 and not wipe.undo_ready(MAGE),
		"party wipe during turn closure prevents enemy actions and undo")


func _solo_finishes_immediately() -> void:
	var state := _combat([MAGE])
	var player := state.players[MAGE]
	player.burning = 2
	_check(state.end_turn(MAGE) and state.round_number == 2 and player.hp == 27,
		"one solo End Turn closes the phase and resolves Burning and enemy actions immediately")
	_check(not state.can_undo_ready(MAGE) and not state.undo_ready(MAGE) and player.mana == CombatState.TURN_MANA,
		"solo never presents a reversible waiting period")


func _lethal_card_wins_during_open_phase() -> void:
	var state := _combat([MAGE, ALLY])
	var waiting := state.players[ALLY]
	waiting.burning = 5
	waiting.hp = 3
	var original := _resources(waiting)
	state.enemy_state(FIRST_SLIME).hp = 0
	state.enemy_state(SECOND_SLIME).hp = 3
	_check(state.end_turn(ALLY) and state.play_card(MAGE, state.players[MAGE].hand[0], SECOND_SLIME)
		and state.phase == CombatState.Phase.VICTORY, "another Mage may win while an ally is Ready")
	_check(_resources(waiting) == original and not state.undo_ready(ALLY)
		and state.enemies[1].action_index == 0, "direct victory skips pending shared-phase cleanup")


func _host_validates_round_ready_epoch_and_target() -> void:
	var authority := Authority.new(_fixture(), {1: MAGE, 20: ALLY})
	var initial_host := authority.snapshot_for(1)
	var initial_ally := authority.snapshot_for(20)
	var copy: int = initial_host.hand[0].copy
	var first_ready := _command(initial_host, 1, Authority.Command.END_TURN)
	var missing_epoch := first_ready.duplicate()
	missing_epoch.erase("ready_epoch")
	_rejected(authority, 1, missing_epoch, Authority.Result.MALFORMED, "host requires readiness epoch")
	_check(authority.submit(1, first_ready) == Authority.Result.ACCEPTED, "host accepts an authenticated Ready")
	var waiting := authority.snapshot_for(1)
	_check(waiting.can_undo_ready and waiting.ready_epoch == 1 and waiting.players[0].ended_turn
		and not authority.snapshot_for(20).can_undo_ready and authority.snapshot_for(20).ready_epoch == 0,
		"ready flags are public while eligibility and readiness epoch belong to the proper viewer")
	_check(_copy_ids(waiting) == _copy_ids(initial_host) and waiting.discard_count == initial_host.discard_count
		and _copy_ids(authority.snapshot_for(20)) == _copy_ids(initial_ally)
		and not waiting.players[0].has("hand") and not waiting.players[0].has("ready_epoch"),
		"waiting keeps each player's own hand private and unplayed cards in that hand")
	_rejected(authority, 1, first_ready, Authority.Result.DUPLICATE, "duplicate Ready packet is rejected")
	var stolen_undo := _command(waiting, 33, Authority.Command.UNDO_READY)
	_rejected(authority, 20, stolen_undo, Authority.Result.WRONG_PLAYER, "another seat cannot undo the host's ready")
	var blocked_play := _command(waiting, 2, Authority.Command.PLAY_CARD)
	blocked_play.merge({"copy": copy, "target": String(SECOND_SLIME)})
	_rejected(authority, 1, blocked_play, Authority.Result.ILLEGAL_ACTION, "a Ready Mage cannot play")
	var accepted_undo := _command(waiting, 3, Authority.Command.UNDO_READY)
	_check(authority.submit(1, accepted_undo) == Authority.Result.ACCEPTED, "host accepts in-phase undo")
	var active := authority.snapshot_for(1)
	_check(not active.players[0].ended_turn and active.ready_epoch == 2 and _copy_ids(active) == _copy_ids(initial_host)
		and active.hand[0].playable, "authoritative undo restores original playable copies")
	_rejected(authority, 1, accepted_undo, Authority.Result.DUPLICATE, "duplicate Undo packet is rejected")
	_rejected(authority, 1, _command(initial_host, 4, Authority.Command.END_TURN), Authority.Result.STALE_TURN,
		"a delayed earlier Ready cannot ready an unready Mage in the same round")
	var wrong_target := _command(active, 5, Authority.Command.PLAY_CARD)
	wrong_target.merge({"copy": copy, "target": "unknown"})
	_rejected(authority, 1, wrong_target, Authority.Result.ILLEGAL_ACTION, "wrong target preserves the undone hand")
	var play := _command(active, 6, Authority.Command.PLAY_CARD)
	play.merge({"copy": copy, "target": String(SECOND_SLIME)})
	_check(authority.submit(1, play) == Authority.Result.ACCEPTED
		and authority.snapshot_for(1).enemies[0].hp == 18 and authority.snapshot_for(1).enemies[1].hp == 19,
		"host applies a retained card only to its selected target")
	_check(authority.submit(1, _command(active, 7, Authority.Command.END_TURN)) == Authority.Result.ACCEPTED,
		"player can ready again with a newer sequence")
	var final_ready := authority.snapshot_for(1)
	_rejected(authority, 1, _command(waiting, 8, Authority.Command.UNDO_READY), Authority.Result.STALE_TURN,
		"a stale same-round Undo cannot undo a newer Ready")
	_check(authority.submit(20, _command(initial_ally, 1, Authority.Command.END_TURN)) == Authority.Result.ACCEPTED,
		"another seat can act on its still-valid snapshot after host Ready changes")
	var next_round := authority.snapshot_for(1)
	_check(next_round.round == 2 and next_round.enemies[0].action_index == 1
		and next_round.enemies[1].action_index == 1 and not next_round.can_undo_ready,
		"final authenticated Ready closes and advances exactly once")
	_rejected(authority, 1, _command(final_ready, 9, Authority.Command.UNDO_READY), Authority.Result.STALE_TURN,
		"late Undo cannot reopen the finalized round")


func _sole_target_is_explicit_on_the_wire() -> void:
	var fixture := _fixture()
	fixture.enemies = [TWO_SLIMES.enemies[0]]
	var authority := Authority.new(fixture, {1: MAGE, 20: ALLY})
	var initial := authority.snapshot_for(1)
	var request := _command(initial, 1, Authority.Command.PLAY_CARD)
	request["copy"] = initial.hand[0].copy
	_rejected(authority, 1, request, Authority.Result.ILLEGAL_ACTION,
		"even a sole enemy needs an explicit target on the wire")
	request["sequence"] = 2
	request["target"] = String(FIRST_SLIME)
	_check(authority.submit(1, request) == Authority.Result.ACCEPTED, "host accepts explicit sole target")


func _combat(seats: Array[StringName], hps: Dictionary[StringName, int] = {}) -> CombatState:
	var fixture := _fixture()
	return CombatState.new(fixture, fixture.shuffle_seed, seats, -1, {}, hps)


func _fixture() -> EncounterData:
	var fixture: EncounterData = TWO_SLIMES.duplicate()
	fixture.test_deck = DECK.duplicate()
	return fixture


func _resources(player: CombatState.PlayerState) -> Array:
	return [player.hand.duplicate(), player.draw_pile.duplicate(), player.discard_pile.duplicate(), player.hp,
		player.mana, player.block, player.poison, player.burning, player.next_attack_bonus]


func _event_count(state: CombatState, fragment: String) -> int:
	var matches := 0
	for line in state.combat_log:
		matches += int(fragment in line)
	return matches


func _command(view: Dictionary, sequence: int, kind: Authority.Command) -> Dictionary:
	return {"actor": view.viewer, "sequence": sequence, "kind": int(kind), "round": view.round,
		"phase": view.phase, "ready_epoch": view.ready_epoch}


func _copy_ids(view: Dictionary) -> Array:
	return view.hand.map(func(card: Dictionary) -> int: return card.copy)


func _rejected(authority: Authority, seat: int, request: Dictionary, result: Authority.Result, label: String) -> void:
	var snapshots := [authority.snapshot_for(1), authority.snapshot_for(20)]
	_check(authority.submit(seat, request) == result, label)
	_check(snapshots == [authority.snapshot_for(1), authority.snapshot_for(20)], label + " without mutation")


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(label)
