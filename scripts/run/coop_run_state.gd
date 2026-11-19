extends RefCounted

const CardData = preload("res://scripts/combat/card_data.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const RunData = preload("res://scripts/run/run_data.gd")

const OPENING := "opening"
const REWARD := "reward"
const BOSS := "boss"
const VICTORY := "victory"
const DEFEAT := "defeat"

var stage := OPENING
var encounter_id := 0
var active_encounter: EncounterData
var active_combat: CombatState

var _data: RunData
var _player_ids: Array[StringName]
var _decks: Dictionary[StringName, Array] = {}
var _current_hps: Dictionary[StringName, int] = {}
var _submitted: Dictionary[StringName, bool] = {}
var _offers: Array[CardData]
var _rng := RandomNumberGenerator.new()


func _init(data: RunData, player_ids: Array[StringName]) -> void:
	_data = data
	_player_ids = player_ids.duplicate()
	_rng.seed = data.run_seed
	_offers = data.eligible_rewards(RunData.BATTLE_MAGE)
	for player_id in _player_ids:
		_decks[player_id] = data.starting_deck.duplicate()
		_current_hps[player_id] = data.player_max_hp
	# The localhost prototype uses the first configured solo opening route.
	_start_encounter(data.opening_encounters[0])


func observe_combat_result() -> void:
	match active_combat.phase:
		CombatState.Phase.DEFEAT:
			stage = DEFEAT
		CombatState.Phase.VICTORY:
			if stage == BOSS:
				stage = VICTORY
			elif stage == OPENING:
				for player_id in _player_ids:
					# The shared resolver has already applied post-victory recovery.
					_current_hps[player_id] = active_combat.players[player_id].hp
				stage = REWARD


func submit_reward(player_id: StringName, card_id: StringName) -> bool:
	if stage != REWARD or not _decks.has(player_id) or _submitted.has(player_id):
		return false
	if card_id != &"":
		var reward: CardData
		for card in _offers:
			if card.id == card_id:
				reward = card
				break
		if reward == null:
			return false
		_decks[player_id].append(reward)
	_submitted[player_id] = true
	if _submitted.size() == _player_ids.size():
		stage = BOSS
		_start_encounter(_data.boss_encounter)
	return true


func view_fields(player_id: StringName) -> Dictionary:
	var view := {"run_stage": stage, "encounter_id": encounter_id, "run_deck_count": _decks[player_id].size()}
	if stage == REWARD:
		var submitted := _submitted.has(player_id)
		var options: Array[Dictionary] = []
		if not submitted:
			for card in _offers:
				options.append({"id": String(card.id), "name": card.display_name, "cost": card.mana_cost,
					"description": card.description()})
		view.merge({"reward_ready": _submitted.size(), "reward_submitted": submitted, "reward_options": options})
	return view


func _start_encounter(definition: EncounterData) -> void:
	active_encounter = definition.duplicate()
	active_encounter.player_max_hp = _data.player_max_hp
	active_encounter.shuffle_seed = _rng.randi()
	active_combat = CombatState.new(active_encounter, active_encounter.shuffle_seed, _player_ids, -1, _decks, _current_hps)
	encounter_id += 1
