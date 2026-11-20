extends RefCounted

const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")


static func build(state: CombatState, encounter: EncounterData, viewer: StringName,
		show_seed: bool = false) -> Dictionary:
	var public_players: Array[Dictionary] = []
	for player in state.players.values():
		public_players.append({
			"id": String(player.id), "hp": player.hp, "max_hp": player.max_hp,
			"mana": player.mana, "block": player.block, "next_attack_bonus": player.next_attack_bonus,
			"poison": player.poison, "burning": player.burning,
			"strength": player.strength, "dexterity": player.dexterity,
			"ended_turn": player.ended_turn, "recovered": player.recovered_after_victory,
		})
	var local := state.players[viewer]
	var public_enemies: Array[Dictionary] = []
	var available_target: StringName = &""
	for enemy in state.enemies:
		public_enemies.append({
			"id": String(enemy.id), "name": enemy.display_name, "hp": enemy.hp, "max_hp": enemy.max_hp,
			"block": enemy.block, "poison": enemy.poison, "burning": enemy.burning,
			"strength": enemy.strength, "dexterity": enemy.dexterity, "intent": enemy.intent(),
			"action_index": enemy.action_index,
			"alive": enemy.is_alive(), "attack_poison": enemy.poison_per_attack,
			"attack_burning": enemy.burning_per_attack,
		})
		if available_target == &"" and enemy.is_alive():
			available_target = enemy.id
	var hand: Array[Dictionary] = []
	for copy_id in local.hand:
		var card := state.card_data(copy_id)
		var targets_enemy := card.targets_enemy()
		var target := available_target if targets_enemy else &""
		hand.append({
			"copy": copy_id, "id": String(card.id), "name": card.display_name, "cost": card.mana_cost,
			"description": card.description(), "approval": card.approval_status, "attack": card.is_attack,
			"playable": state.can_play_card(viewer, copy_id, target), "targets_enemy": targets_enemy,
		})
	var first_enemy := state.enemies[0]
	var enemy_label := first_enemy.display_name if state.enemies.size() == 1 else encounter.enemy_name
	var snapshot := {
		"viewer": String(viewer), "phase": int(state.phase), "round": state.round_number,
		"revision": state.action_history.size(), "players": public_players,
		"enemies": public_enemies,
		"enemy_name": enemy_label, "enemy_hp": state.enemy_hp, "enemy_max_hp": first_enemy.max_hp,
		"enemy_poison": state.enemy_poison, "enemy_burning": state.enemy_burning,
		"enemy_strength": state.enemy_strength, "enemy_dexterity": state.enemy_dexterity,
		"enemy_poison_per_attack": first_enemy.poison_per_attack,
		"enemy_burning_per_attack": first_enemy.burning_per_attack,
		"enemy_block": state.enemy_block, "enemy_intent": state.enemy_intent(),
		"enemy_attack": state.enemy_attack_damage(), "hand": hand, "draw_count": local.draw_pile.size(),
		"discard_count": local.discard_pile.size(), "can_end_turn": state.can_end_turn(viewer),
		# The first resolver log line contains the seed. Publish only the subsequent combat events.
		"log": state.combat_log if show_seed else state.combat_log.slice(1),
	}
	if show_seed:
		snapshot["seed"] = state.shuffle_seed
	return snapshot
