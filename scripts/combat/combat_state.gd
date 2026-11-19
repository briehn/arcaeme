extends RefCounted

const CardData = preload("res://scripts/combat/card_data.gd")
const CardEffect = preload("res://scripts/combat/card_effect.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")

enum Phase { PLAYER, ENEMY, VICTORY, DEFEAT }

const TURN_MANA := 3
const TURN_DRAW := 5


class PlayerState:
	var id: StringName
	var hp: int
	var max_hp: int
	var mana: int
	var block: int
	var poison: int
	var burning: int
	var next_attack_bonus: int
	var ended_turn: bool
	var recovered_after_victory: bool
	var first_copy_id: int
	var hand: Array[int] = []
	var draw_pile: Array[int] = []
	var discard_pile: Array[int] = []


var phase: Phase = Phase.PLAYER
var round_number: int
var shuffle_seed: int
var enemy_hp: int
var enemy_poison: int
var enemy_burning: int
var players: Dictionary[StringName, PlayerState] = {}
var action_history: Array[Dictionary] = []
var combat_log: PackedStringArray = []

var _encounter: EncounterData
var _cards: Array[CardData] = []
var _rng := RandomNumberGenerator.new()


func _init(encounter: EncounterData, encounter_seed: int, player_ids: Array[StringName], starting_hp := -1,
		player_decks: Dictionary[StringName, Array] = {}, player_hps: Dictionary[StringName, int] = {}) -> void:
	assert(not player_ids.is_empty(), "Combat requires at least one player.")
	_encounter = encounter
	shuffle_seed = encounter_seed
	_rng.seed = shuffle_seed
	enemy_hp = _encounter.enemy_max_hp
	_log("Encounter started. Seed %d." % shuffle_seed)
	for player_id in player_ids:
		assert(not players.has(player_id), "Combat player IDs must be unique.")
		var player := PlayerState.new()
		player.id = player_id
		player.max_hp = _encounter.player_max_hp
		player.hp = player_hps.get(player_id, player.max_hp if starting_hp < 0 else starting_hp)
		player.first_copy_id = _cards.size()
		for card in player_decks.get(player_id, _encounter.test_deck):
			player.draw_pile.append(_cards.size())
			_cards.append(card)
		_shuffle(player.draw_pile)
		players[player_id] = player
	_begin_player_phase()


func card_data(copy_id: int) -> CardData:
	return _cards[copy_id]


func can_play_card(player_id: StringName, copy_id: int, target_id: StringName) -> bool:
	var player: PlayerState = players.get(player_id)
	if not _can_act(player) or not player.hand.has(copy_id):
		return false
	var card := card_data(copy_id)
	var expected_target := _encounter.enemy_id if card.targets_enemy() else &""
	return player.mana >= card.mana_cost and target_id == expected_target


func play_card(player_id: StringName, copy_id: int, target_id: StringName) -> bool:
	if not can_play_card(player_id, copy_id, target_id):
		return false
	var player := players[player_id]
	var card := card_data(copy_id)
	action_history.append({&"command": &"play_card", &"player": player_id,
		&"copy": copy_id, &"target": target_id})
	player.mana -= card.mana_cost
	player.hand.erase(copy_id)
	_log("%s played %s for %d Mana." % [player.id, card.display_name, card.mana_cost])
	for effect in card.effects:
		match effect.kind:
			CardEffect.Kind.DAMAGE:
				_deal_card_damage(player, card, effect)
			CardEffect.Kind.GAIN_BLOCK:
				player.block += effect.amount
				_log("%s gained %d Block." % [player.id, effect.amount])
			CardEffect.Kind.DRAW:
				_draw(player, effect.amount)
			CardEffect.Kind.PREPARE_ATTACK:
				# TODO(design): Multiple preparations add to the same next Attack in this playtest.
				player.next_attack_bonus += effect.amount
				_log("%s prepared their next Attack for +%d damage this turn." % [
					player.id, player.next_attack_bonus])
			CardEffect.Kind.APPLY_POISON, CardEffect.Kind.APPLY_BURNING:
				_apply_card_status(effect)
	player.discard_pile.append(copy_id)
	if enemy_hp == 0:
		_resolve_victory()
	return true


func can_end_turn(player_id: StringName) -> bool:
	return _can_act(players.get(player_id))


func end_turn(player_id: StringName) -> bool:
	var player: PlayerState = players.get(player_id)
	if not _can_act(player):
		return false
	action_history.append({&"command": &"end_turn", &"player": player_id})
	player.ended_turn = true
	player.mana = 0
	if player.next_attack_bonus > 0:
		_log("%s's next Attack bonus expired at turn end." % player.id)
		player.next_attack_bonus = 0
	if not player.hand.is_empty():
		_log("%s discarded %d unplayed cards." % [player.id, player.hand.size()])
		player.discard_pile.append_array(player.hand)
		player.hand.clear()
	_log("%s ended their turn." % player.id)
	if player.burning > 0:
		player.hp = _take_status_damage(player.hp, player.burning, "Burning", player.id)
		player.burning = _remaining_burning(player.burning)
		if player.hp == 0:
			_log("%s was defeated." % player.id)
			if _finish_if_party_down():
				return true
	for other: PlayerState in players.values():
		if other.hp > 0 and not other.ended_turn:
			return true
	_resolve_enemy_phase()
	return true


func _deal_card_damage(player: PlayerState, card: CardData, effect: CardEffect) -> void:
	var damage := effect.amount
	if effect.block_per_bonus > 0:
		@warning_ignore("integer_division")
		var block_bonus := player.block / effect.block_per_bonus
		damage += block_bonus
		_log("%s added %d damage from %d Block." % [card.display_name, block_bonus, player.block])
	if effect.block_to_spend > 0:
		if player.block >= effect.block_to_spend:
			player.block -= effect.block_to_spend
			damage += effect.damage_on_block_spend
			_log("%s spent %d Block for +%d damage." % [
				card.display_name, effect.block_to_spend, effect.damage_on_block_spend])
		else:
			_log("%s needs %d Block for bonus damage. %s has %d Block and spent none." % [
				card.display_name, effect.block_to_spend, player.id, player.block])
	# TODO(design): Apply preparation once, to the first hit of the owner's next Attack.
	if card.is_attack and player.next_attack_bonus > 0:
		damage += player.next_attack_bonus
		_log("%s used their preparation for +%d Attack damage." % [player.id, player.next_attack_bonus])
		player.next_attack_bonus = 0
	var hp_lost := mini(enemy_hp, damage)
	enemy_hp -= hp_lost
	_log("%s took %d damage." % [_encounter.enemy_name, hp_lost])


func _apply_card_status(effect: CardEffect) -> void:
	if enemy_hp == 0 or effect.amount <= 0:
		return
	if effect.kind == CardEffect.Kind.APPLY_POISON:
		enemy_poison += effect.amount
		_log_status_application(_encounter.enemy_name, effect.amount, "Poison")
	else:
		# Provisional: repeated Burning applications add their stacks.
		enemy_burning += effect.amount
		_log_status_application(_encounter.enemy_name, effect.amount, "Burning")


func _take_status_damage(hp: int, stacks: int, status_name: String, target: String) -> int:
	var hp_lost := mini(hp, stacks)
	_log("%s lost %d HP to %s." % [target, hp_lost, status_name])
	return hp - hp_lost


func _remaining_burning(stacks: int) -> int:
	@warning_ignore("integer_division")
	return stacks - stacks / 2


func _can_act(player: PlayerState) -> bool:
	return phase == Phase.PLAYER and player != null and player.hp > 0 and not player.ended_turn


func _begin_player_phase() -> void:
	phase = Phase.PLAYER
	round_number += 1
	_log("Turn %d. Player phase." % round_number)
	for player: PlayerState in players.values():
		if player.hp <= 0:
			continue
		if player.block > 0:
			_log("%s lost %d remaining Block at turn start." % [player.id, player.block])
		player.block = 0
		if player.poison > 0:
			player.hp = _take_status_damage(player.hp, player.poison, "Poison", player.id)
			player.poison -= 1
			if player.hp == 0:
				_log("%s was defeated." % player.id)
				continue
		player.mana = TURN_MANA
		player.ended_turn = false
		_draw(player, TURN_DRAW)
	_finish_if_party_down()


func _resolve_enemy_phase() -> void:
	phase = Phase.ENEMY
	if enemy_poison > 0:
		enemy_hp = _take_status_damage(enemy_hp, enemy_poison, "Poison", _encounter.enemy_name)
		enemy_poison -= 1
		if enemy_hp == 0:
			_resolve_victory()
			return
	_log("%s attacks for %d damage." % [_encounter.enemy_name, _encounter.enemy_attack])
	for player: PlayerState in players.values():
		if player.hp <= 0:
			continue
		var absorbed := mini(player.block, _encounter.enemy_attack)
		var hp_lost := mini(player.hp, _encounter.enemy_attack - absorbed)
		player.block -= absorbed
		player.hp -= hp_lost
		_log("%s blocked %d and lost %d HP." % [player.id, absorbed, hp_lost])
		if player.hp == 0:
			_log("%s was defeated." % player.id)
			continue
		_apply_attack_statuses(player)
	# Provisional: a lethal enemy attack ends the encounter before its end-turn status tick.
	if _finish_if_party_down():
		return
	if enemy_burning > 0:
		enemy_hp = _take_status_damage(enemy_hp, enemy_burning, "Burning", _encounter.enemy_name)
		enemy_burning = _remaining_burning(enemy_burning)
		if enemy_hp == 0:
			_resolve_victory()
			return
	_begin_player_phase()


func _apply_attack_statuses(player: PlayerState) -> void:
	if _encounter.enemy_poison_per_attack > 0:
		player.poison += _encounter.enemy_poison_per_attack
		_log_status_application(player.id, _encounter.enemy_poison_per_attack, "Poison")
	if _encounter.enemy_burning_per_attack > 0:
		player.burning += _encounter.enemy_burning_per_attack
		_log_status_application(player.id, _encounter.enemy_burning_per_attack, "Burning")


func _log_status_application(target: String, amount: int, status_name: String) -> void:
	_log("%s gained %d %s stacks." % [target, amount, status_name])


func _finish_if_party_down() -> bool:
	for player: PlayerState in players.values():
		if player.hp > 0:
			return false
	phase = Phase.DEFEAT
	_log("Defeat.")
	return true


func _resolve_victory() -> void:
	phase = Phase.VICTORY
	_log("Victory. %s was defeated." % _encounter.enemy_name)
	for player: PlayerState in players.values():
		if player.hp == 0:
			@warning_ignore("integer_division")
			player.hp = player.max_hp / 4 + int(player.max_hp % 4 != 0)
			player.recovered_after_victory = true
			_log("%s recovered to %d/%d HP after victory." % [player.id, player.hp, player.max_hp])


func _draw(player: PlayerState, count: int) -> void:
	var drawn := 0
	while drawn < count:
		if player.draw_pile.is_empty():
			if player.discard_pile.is_empty():
				break
			player.draw_pile.assign(player.discard_pile)
			player.discard_pile.clear()
			_shuffle(player.draw_pile)
			_log("%s shuffled their discard pile into the draw pile." % player.id)
		player.hand.append(player.draw_pile.pop_back())
		drawn += 1
	_log("%s drew %d %s." % [player.id, drawn, "card" if drawn == 1 else "cards"])


func _shuffle(pile: Array[int]) -> void:
	for index in range(pile.size() - 1, 0, -1):
		var other_index := _rng.randi_range(0, index)
		var card := pile[index]
		pile[index] = pile[other_index]
		pile[other_index] = card


func _log(message: String) -> void:
	combat_log.append(message)
