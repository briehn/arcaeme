extends SceneTree

const CardEffect = preload("res://scripts/combat/card_effect.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const CoopRunState = preload("res://scripts/run/coop_run_state.gd")
const RunData = preload("res://scripts/run/run_data.gd")
const RunState = preload("res://scripts/run/run_state.gd")
const ROUTE = preload("res://resources/prototype/enemy_variety_run.tres")
const ORIGINAL = preload("res://resources/prototype/battle_mage_run.tres")
const SLIME = preload("res://resources/prototype/enemies/slime.tres")
const SEATS: Array[StringName] = [&"Battle Mage 1", &"Battle Mage 2", &"Battle Mage 3", &"Battle Mage 4"]
const DEFINING_DAMAGE := {&"goblin": 14, &"treant": 10, &"slime": 6}

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_check(ROUTE.starting_deck == ORIGINAL.starting_deck and ROUTE.reward_candidates == ORIGINAL.reward_candidates
		and ROUTE.run_seed == ORIGINAL.run_seed and ROUTE.player_max_hp == ORIGINAL.player_max_hp,
		"the comparison keeps the existing starter deck, reward pool, seed and Mage HP")
	var control: RunData = ROUTE.duplicate()
	control.opening_encounters = [SLIME]
	for size in range(1, 5):
		for cover_intent in [false, true]:
			var route := _evaluate(ROUTE, size, cover_intent)
			_check(route == _evaluate(ROUTE, size, cover_intent), "seeded variety run replays exactly")
			print("METRIC ", JSON.stringify(route))
			var baseline := _evaluate(control, size, cover_intent, false)
			_check(baseline == _evaluate(control, size, cover_intent, false), "seeded Slime control replays exactly")
			print("METRIC ", JSON.stringify(baseline))
	print("Enemy variety evaluation: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _evaluate(data: RunData, size: int, cover_intent: bool, play_final := true) -> Dictionary:
	var fights: Array[Dictionary]
	if size == 1:
		fights = _solo(data, cover_intent, play_final)
	else:
		fights = _coop(data, size, cover_intent, play_final)
	return {"party": size, "policy": "cover-intent" if cover_intent else "attack-first", "fights": fights}


func _solo(data: RunData, cover_intent: bool, play_final: bool) -> Array[Dictionary]:
	var run := RunState.new(data)
	run.choose_opening(data.opening_encounters[0].enemy_id)
	var fights: Array[Dictionary] = [_fight(run.active_combat, run.active_encounter.enemy_id,
		run.active_encounter.enemy_name, cover_intent)]
	if play_final and run.finish_combat(run.active_combat) and run.stage == RunState.Stage.REWARD:
		_check(run.take_reward(&"shieldstrike") and run.start_boss(), "solo reward and final encounter")
		fights.append(_fight(run.active_combat, run.active_encounter.enemy_id,
			run.active_encounter.enemy_name, cover_intent))
		run.finish_combat(run.active_combat)
		_check(run.stage in [RunState.Stage.VICTORY, RunState.Stage.DEFEAT], "solo run settles")
	return fights


func _coop(data: RunData, size: int, cover_intent: bool, play_final: bool) -> Array[Dictionary]:
	var players: Array[StringName] = SEATS.slice(0, size)
	var run := CoopRunState.new(data, players)
	var fights: Array[Dictionary] = [_fight(run.active_combat, run.active_encounter.enemy_id,
		run.active_encounter.enemy_name, cover_intent)]
	run.observe_combat_result()
	if play_final and run.stage == CoopRunState.REWARD:
		for player_id in players:
			var pick := &"shieldstrike" if player_id == players[0] else &""
			_check(run.submit_reward(player_id, pick), "personal party reward decision")
		fights.append(_fight(run.active_combat, run.active_encounter.enemy_id,
			run.active_encounter.enemy_name, cover_intent))
		run.observe_combat_result()
		_check(run.stage in [CoopRunState.VICTORY, CoopRunState.DEFEAT], "co-op run settles")
	return fights


func _fight(combat: CombatState, enemy_id: StringName, enemy_name: String, cover_intent: bool) -> Dictionary:
	var start_hp: Array[int] = []
	var card_counts: Dictionary[StringName, int] = {}
	for player: CombatState.PlayerState in combat.players.values():
		start_hp.append(player.hp)
		card_counts[player.id] = 0
	while combat.phase == CombatState.Phase.PLAYER and combat.round_number <= 40:
		for player_id in combat.players:
			if not combat.can_end_turn(player_id):
				continue
			var card := _choose_card(combat, player_id, enemy_id, cover_intent)
			while card >= 0:
				var target := enemy_id if combat.card_data(card).targets_enemy() else &""
				if not combat.play_card(player_id, card, target):
					_check(false, "chosen card must remain legal")
					break
				card_counts[player_id] += 1
				card = _choose_card(combat, player_id, enemy_id, cover_intent)
			if combat.can_end_turn(player_id):
				combat.end_turn(player_id)
	_check(combat.phase in [CombatState.Phase.VICTORY, CombatState.Phase.DEFEAT], "fight settles within test limit")
	var attacks: Array[int] = []
	var attack_prefix := "%s attacks for " % enemy_name
	for line in combat.combat_log:
		if line.begins_with(attack_prefix):
			attacks.append(line.trim_prefix(attack_prefix).get_slice(" ", 0).to_int())
	var end_hp: Array[int] = []
	var hp_lost: Array[int] = []
	for player: CombatState.PlayerState in combat.players.values():
		# These fixtures have no combat healing. Recovery after victory returns a downed seat from 0 HP.
		hp_lost.append(start_hp[end_hp.size()] - (0 if player.recovered_after_victory else player.hp))
		end_hp.append(player.hp)
	return {"enemy": enemy_name, "outcome": CombatState.Phase.keys()[combat.phase],
		"rounds": combat.round_number, "start_hp": start_hp, "hp_lost": hp_lost, "end_hp": end_hp,
		"attacks": attacks, "defining_attack": attacks.has(DEFINING_DAMAGE[enemy_id]),
		"cards": card_counts.values(), "trace": JSON.stringify(combat.combat_log).sha256_text()}


func _choose_card(combat: CombatState, player_id: StringName, enemy_id: StringName, cover_intent: bool) -> int:
	var player := combat.players[player_id]
	var needs_block := cover_intent and player.block < combat.enemy_attack_damage()
	var first_available := -1
	var first_attack := -1
	for copy_id in player.hand:
		var card := combat.card_data(copy_id)
		var target := enemy_id if card.targets_enemy() else &""
		if not combat.can_play_card(player_id, copy_id, target):
			continue
		if first_available < 0:
			first_available = copy_id
		if card.is_attack and first_attack < 0:
			first_attack = copy_id
		if needs_block:
			for effect in card.effects:
				if effect.kind == CardEffect.Kind.GAIN_BLOCK:
					return copy_id
	return first_attack if first_attack >= 0 else first_available


func _check(condition: bool, context: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr(context)
