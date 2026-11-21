extends "res://tests/multi_enemy_run_evaluation.gd"

const Pool = preload("res://scripts/run/battle_mage_pool_playtest.gd")

# Rank rewards by the draft's plan, then take the first offered card as a fallback.
const PICKS := {
	"spellblade": [&"twin_sigil", &"astral_salvo", &"spellsteel_oath", &"spellforge", &"keystone_cut", &"shieldstrike"],
	"defense": [&"aegis_temper", &"prism_wall", &"mirror_lunge", &"shieldstrike", &"glimmer_ward", &"arcane_guard"],
	"cycling": [&"rune_survey", &"tacticians_page", &"arcane_study", &"ember_script", &"rune_cut", &"arcane_guard"],
	"risk": [&"searing_brand", &"kindled_focus", &"shatterguard", &"arcane_reversal", &"ember_script", &"battle_preparation"],
}
const COMBAT_POLICIES := {
	"spellblade": "focus-threat",
	"defense": "cover-and-focus",
	"cycling": "cover-and-focus",
	"risk": "cover-and-focus",
}

var _profile: String
var _card_usage := {}


func _initialize() -> void:
	for card in Pool.NEW_CARDS:
		_card_usage[card.id] = {"takes": 0, "plays": 0}
	var expanded := Pool.with_expanded_rewards(ROUTE)
	var pairs := 0
	for size in range(1, 5):
		var roster := SEATS.slice(0, size)
		if size == 1:
			roster[0] = RunState.PLAYER_ID
		for profile: String in PICKS:
			_profile = profile
			var base_group: Array[Dictionary] = []
			var expanded_group: Array[Dictionary] = []
			for index in SEEDS.size():
				var seed := SEEDS[index]
				var baseline := _run_sample(roster, seed, index, COMBAT_POLICIES[profile])
				var result := _run_sample(roster, seed, index, COMBAT_POLICIES[profile], expanded)
				_check(result == _run_sample(roster, seed, index, COMBAT_POLICIES[profile], expanded),
					"expanded draft and combat trace replay with identical inputs")
				_check(baseline.encounters[0].trace == result.encounters[0].trace,
					"expanded offers do not alter combat randomness before the first reward")
				_record_card_usage(result)
				base_group.append(baseline)
				expanded_group.append(result)
				pairs += 1
				print("POOL_SAMPLE ", JSON.stringify({
					"party": size, "profile": profile, "base": baseline, "expanded": result,
				}))
			print("POOL_SUMMARY ", JSON.stringify({
				"party": size, "profile": profile, "cases": SEEDS.size(),
				"base": _outcomes(base_group), "expanded": _outcomes(expanded_group),
			}))
	print("POOL_USAGE ", JSON.stringify(_card_usage))
	print("Battle Mage pool evaluation: %d matched pairs, %d checks, %d failures." % [pairs, _checks, _failures])
	quit(int(_failures > 0))


func _draft_reward(offers: Array, _seed: int, _seed_index: int, _seat: int, _encounter_id: int) -> StringName:
	for id: StringName in PICKS[_profile]:
		for card in offers:
			if card.id == id:
				return id
	return offers[0].id


func _record_card_usage(result: Dictionary) -> void:
	for rewards: Array in result.rewards.values():
		for reward: Dictionary in rewards:
			var id := StringName(reward.card)
			if _card_usage.has(id):
				_card_usage[id].takes += 1
	for fight: Dictionary in result.encounters:
		for player: Dictionary in fight.players.values():
			for key: String in player.reward_cards:
				var id := StringName(key.get_slice(":", 1))
				if _card_usage.has(id):
					_card_usage[id].plays += player.reward_cards[key]


func _outcomes(group: Array[Dictionary]) -> Dictionary:
	var totals := {"wins": 0, "boss_reached": 0, "boss_rounds": 0, "enemy_burning_hp_lost": 0, "party_final_hp": 0}
	for result in group:
		totals.wins += int(result.victory)
		if result.encounters.size() == ROUTE.encounter_count():
			totals.boss_reached += 1
			totals.boss_rounds += result.encounters.back().rounds
		for hp: int in result.final_hp.values():
			totals.party_final_hp += hp
		for fight: Dictionary in result.encounters:
			totals.enemy_burning_hp_lost += fight.status_hp_loss.burning
	return totals
