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
	var hand: Array[Dictionary] = []
	for copy_id in local.hand:
		var card := state.card_data(copy_id)
		var target := encounter.enemy_id if card.targets_enemy() else &""
		hand.append({
			"copy": copy_id, "id": String(card.id), "name": card.display_name, "cost": card.mana_cost,
			"description": card.description(), "approval": card.approval_status, "attack": card.is_attack,
			"playable": state.can_play_card(viewer, copy_id, target),
		})
	var snapshot := {
		"viewer": String(viewer), "phase": int(state.phase), "round": state.round_number,
		"revision": state.action_history.size(), "players": public_players,
		"enemy_name": encounter.enemy_name, "enemy_hp": state.enemy_hp, "enemy_max_hp": encounter.enemy_max_hp,
		"enemy_poison": state.enemy_poison, "enemy_burning": state.enemy_burning,
		"enemy_strength": state.enemy_strength, "enemy_dexterity": state.enemy_dexterity,
		"enemy_poison_per_attack": encounter.enemy_poison_per_attack,
		"enemy_burning_per_attack": encounter.enemy_burning_per_attack,
		"enemy_attack": state.enemy_attack_damage(), "hand": hand, "draw_count": local.draw_pile.size(),
		"discard_count": local.discard_pile.size(), "can_end_turn": state.can_end_turn(viewer),
		# The first resolver log line contains the seed. Publish only the subsequent combat events.
		"log": state.combat_log if show_seed else state.combat_log.slice(1),
	}
	if show_seed:
		snapshot["seed"] = state.shuffle_seed
	return snapshot
