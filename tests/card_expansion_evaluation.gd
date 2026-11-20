extends "res://tests/enemy_variety_evaluation.gd"

const Expansion = preload("res://scripts/run/card_expansion_playtest.gd")
const CANDIDATE_IDS := ["astral_salvo", "rune_cut", "warded_strike", "prism_wall", "arcane_study", "spellforge"]

var _candidate_usage: Dictionary
var _usage_totals: Dictionary[String, int] = {}


func _initialize() -> void:
	for id in CANDIDATE_IDS:
		_usage_totals[id] = 0
	for seed_index in SEEDS.size():
		var template: RunData = ROUTE.duplicate()
		template.run_seed = SEEDS[seed_index]
		var expansion := Expansion.with_expansion_run(template)
		_check(expansion.starting_deck.size() == template.starting_deck.size()
			and expansion.opening_encounters == template.opening_encounters and expansion.boss_encounter == template.boss_encounter
			and expansion.reward_candidates == template.reward_candidates and expansion.player_max_hp == template.player_max_hp
			and expansion.run_seed == template.run_seed, "the matched runs differ only in starting card composition")
		for size in range(1, 5):
			for cover_intent in [false, true]:
				for order_offset in ([-1] if size == 1 else [-1, seed_index]):
					_measure_deck(template, "original", size, cover_intent, order_offset)
					_measure_deck(expansion, "expansion", size, cover_intent, order_offset)
	for id in CANDIDATE_IDS:
		_check(_usage_totals[id] > 0, "%s is played in at least one matched expansion run" % id)
	print("Card expansion evaluation: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _measure_deck(data: RunData, label: String, size: int, cover_intent: bool, order_offset: int) -> void:
	var first := _evaluate_deck(data, label, size, cover_intent, order_offset)
	var replay := _evaluate_deck(data, label, size, cover_intent, order_offset)
	_check(first == replay, "the same deck, seed, policy, seats and rewards reproduce actions and metrics")
	for id in CANDIDATE_IDS:
		var plays: int = first.candidates[id].plays
		if label == "original":
			_check(plays == 0, "the control deck cannot play %s" % id)
		else:
			_usage_totals[id] += plays
	print("EXPANSION_METRIC ", JSON.stringify(first))


func _evaluate_deck(data: RunData, label: String, size: int, cover_intent: bool, order_offset: int) -> Dictionary:
	_candidate_usage = {}
	for id in CANDIDATE_IDS:
		_candidate_usage[id] = {"plays": 0, "mana_spent": 0, "opening_plays": 0, "final_plays": 0}
	var result := _evaluate(data, label, size, cover_intent, order_offset, true, true)
	result["candidates"] = _candidate_usage
	return result


func _play_slot(combat: CombatState, player_id: StringName, enemy_id: StringName, cover_intent: bool,
		seat: Dictionary) -> void:
	var first_action := combat.action_history.size()
	super._play_slot(combat, player_id, enemy_id, cover_intent, seat)
	for index in range(first_action, combat.action_history.size()):
		var action: Dictionary = combat.action_history[index]
		if action.command != &"play_card":
			continue
		var card := combat.card_data(action.copy)
		var id := String(card.id)
		if _candidate_usage.has(id):
			var usage: Dictionary = _candidate_usage[id]
			usage.plays += 1
			usage.mana_spent += card.mana_cost
			if enemy_id == &"goblin":
				usage.opening_plays += 1
			else:
				usage.final_plays += 1


func _is_meaningful(card: CardData) -> bool:
	if super._is_meaningful(card):
		return true
	for effect in card.effects:
		if effect.kind == CardEffect.Kind.DRAW and effect.amount > 0:
			return true
	return false
