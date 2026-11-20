extends RefCounted

const CardData = preload("res://scripts/combat/card_data.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const RunData = preload("res://scripts/run/run_data.gd")

const OPENING := "opening"
const INTERMEDIATE := "intermediate"
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
var _reward_choices: Dictionary[StringName, Array] = {}
var _reward_ready := 0
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
		_reward_choices[player_id] = []
	# Co-op uses the first configured opening encounter.
	_start_encounter(data.opening_encounters[0])


func observe_combat_result() -> void:
	if stage == REWARD or stage == VICTORY or stage == DEFEAT:
		return
	match active_combat.phase:
		CombatState.Phase.DEFEAT:
			stage = DEFEAT
		CombatState.Phase.VICTORY:
			if stage == BOSS:
				stage = VICTORY
			else:
				for player_id in _player_ids:
					# The shared resolver has already applied post-victory recovery.
					_current_hps[player_id] = active_combat.players[player_id].hp
				stage = REWARD


func deck_cards(player_id: StringName) -> Array[CardData]:
	var cards: Array[CardData] = []
	cards.assign(_decks.get(player_id, []))
	return cards


## A seat's decisions in encounter order. An empty ID records a skip.
func reward_choices(player_id: StringName) -> Array[StringName]:
	var choices: Array[StringName] = []
	choices.assign(_reward_choices.get(player_id, []))
	return choices


func submit_reward(player_id: StringName, card_id: StringName) -> bool:
	if (stage != REWARD or not _reward_choices.has(player_id)
			or _reward_choices[player_id].size() != encounter_id - 1):
		return false
	var next := _data.encounter_after(encounter_id)
	if next == null:
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
	_reward_choices[player_id].append(card_id)
	_reward_ready += 1
	if _reward_ready == _player_ids.size():
		stage = BOSS if encounter_id + 1 == _data.encounter_count() else INTERMEDIATE
		_start_encounter(next)
	return true


func view_fields(player_id: StringName) -> Dictionary:
	var view := {
		"run_stage": stage, "encounter_id": encounter_id,
		"encounter_count": _data.encounter_count(), "run_deck_count": _decks[player_id].size(),
	}
	if not _data.title.is_empty():
		view["run_title"] = _data.title
	if stage == REWARD:
		var submitted := _reward_choices[player_id].size() == encounter_id
		var options: Array[Dictionary] = []
		if not submitted:
			for card in _offers:
				options.append({"id": String(card.id), "name": card.display_name, "cost": card.mana_cost,
					"description": card.description()})
		var next := _data.encounter_after(encounter_id)
		view.merge({
			"reward_ready": _reward_ready, "reward_submitted": submitted, "reward_options": options,
			"next_encounter_name": next.enemy_name if next != null else "",
		})
	return view


func _start_encounter(definition: EncounterData) -> void:
	active_encounter = definition.duplicate()
	active_encounter.player_max_hp = _data.player_max_hp
	active_encounter.shuffle_seed = _rng.randi()
	active_combat = CombatState.new(active_encounter, active_encounter.shuffle_seed, _player_ids, -1, _decks, _current_hps)
	_reward_ready = 0
	encounter_id += 1
