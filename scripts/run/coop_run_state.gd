extends RefCounted

const CardData = preload("res://scripts/combat/card_data.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const MajorArcana = preload("res://scripts/run/major_arcana.gd")
const PortalRoute = preload("res://scripts/run/portal_route.gd")
const RunData = preload("res://scripts/run/run_data.gd")

const OPENING := "opening"
const ARCANA := "arcana"
const INTERMEDIATE := "intermediate"
const REWARD := "reward"
const PORTAL := "portal"
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
var _arcana_offers: Dictionary[StringName, Array] = {}
var _arcana_choices: Dictionary[StringName, StringName] = {}
var _portal_choices: Dictionary[StringName, StringName] = {}
var _portal_route: PortalRoute
var _reward_ready := 0
var _offers: Dictionary[StringName, Array] = {}
var _offer_seed: Variant
var _rng := RandomNumberGenerator.new()


func _init(data: RunData, player_ids: Array[StringName], offer_seed: Variant = null) -> void:
	_data = data
	_player_ids = player_ids.duplicate()
	_rng.seed = data.run_seed
	_offer_seed = offer_seed
	if data.portal_enabled:
		_portal_route = PortalRoute.new(data.run_seed)
	for player_id in _player_ids:
		_decks[player_id] = data.starting_deck.duplicate()
		_current_hps[player_id] = data.player_max_hp
		_reward_choices[player_id] = []
	if data.major_arcana_enabled:
		stage = ARCANA
		var arcana_seed := data.run_seed if offer_seed == null else int(offer_seed)
		for seat in _player_ids.size():
			_arcana_offers[_player_ids[seat]] = MajorArcana.offers(arcana_seed, seat, RunData.BATTLE_MAGE)
	else:
		_start_encounter(data.opening_encounters[0])


func selected_arcana(player_id: StringName) -> StringName:
	return _arcana_choices.get(player_id, &"")


func submit_arcana(player_id: StringName, id: StringName) -> bool:
	if stage != ARCANA or not _arcana_offers.has(player_id) or _arcana_choices.has(player_id):
		return false
	if id != &"" and id not in _arcana_offers[player_id]:
		return false
	_arcana_choices[player_id] = id
	if _arcana_choices.size() == _player_ids.size():
		_arcana_offers.clear()
		stage = OPENING
		# Co-op uses the first configured opening encounter.
		_start_encounter(_data.opening_encounters[0])
	return true


func observe_combat_result() -> void:
	if active_combat == null or stage in [REWARD, PORTAL, VICTORY, DEFEAT]:
		return
	match active_combat.phase:
		CombatState.Phase.DEFEAT:
			stage = DEFEAT
		CombatState.Phase.VICTORY:
			if stage == BOSS:
				stage = VICTORY
			else:
				for seat in _player_ids.size():
					var player_id := _player_ids[seat]
					# The shared resolver has already applied post-victory recovery.
					_current_hps[player_id] = active_combat.players[player_id].hp
					_offers[player_id] = _data.reward_offers(RunData.BATTLE_MAGE, encounter_id, seat, _offer_seed)
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
	if _portal_route == null and next == null:
		return false
	if card_id != &"":
		var reward: CardData
		for card: CardData in _offers[player_id]:
			if card.id == card_id:
				reward = card
				break
		if reward == null:
			return false
		_decks[player_id].append(reward)
	_reward_choices[player_id].append(card_id)
	_reward_ready += 1
	if _reward_ready == _player_ids.size():
		_offers.clear()
		if _portal_route != null:
			stage = PORTAL
		else:
			stage = BOSS if encounter_id + 1 == _data.encounter_count() else INTERMEDIATE
			_start_encounter(next)
	return true


func submit_portal(player_id: StringName, id: StringName) -> bool:
	if stage != PORTAL or not _decks.has(player_id) or _portal_choices.has(player_id):
		return false
	var source_id := active_encounter.enemy_id
	if _portal_route.destination(source_id, id) == null:
		return false
	_portal_choices[player_id] = id
	if _portal_choices.size() == _player_ids.size():
		# Slot order makes the seeded draw independent of RPC arrival order.
		var choices: Array[StringName] = []
		for seat in _player_ids:
			choices.append(_portal_choices[seat])
		var chosen := _portal_route.destination(source_id, _portal_route.resolve(choices))
		stage = BOSS if chosen.enemy_id == PortalRoute.BOSS else INTERMEDIATE
		_start_encounter(chosen)
	return true


func view_fields(player_id: StringName) -> Dictionary:
	var view := {
		"run_stage": stage, "encounter_id": encounter_id,
		"encounter_count": _data.encounter_count(), "run_deck_count": _decks[player_id].size(),
	}
	if not _data.title.is_empty():
		view["run_title"] = _data.title
	if stage == ARCANA:
		var submitted := _arcana_choices.has(player_id)
		var options: Array[Dictionary] = []
		if not submitted:
			for id: StringName in _arcana_offers[player_id]:
				options.append(MajorArcana.view(id))
		view.merge({
			"arcana_ready": _arcana_choices.size(), "arcana_submitted": submitted, "arcana_options": options,
		})
	elif stage == REWARD:
		var submitted := _reward_choices[player_id].size() == encounter_id
		var options: Array[Dictionary] = []
		if not submitted:
			for card: CardData in _offers[player_id]:
				options.append({"id": String(card.id), "name": card.display_name, "cost": card.mana_cost,
					"description": card.description()})
		var next := _data.encounter_after(encounter_id)
		view.merge({
			"reward_ready": _reward_ready, "reward_submitted": submitted, "reward_options": options,
			"next_encounter_name": next.enemy_name if next != null else "",
		})
		if _portal_route != null:
			view["portal_after_reward"] = true
	elif stage == PORTAL:
		view.merge({
			"portal_options": _portal_route.options(active_encounter.enemy_id),
			"portal_ready": _portal_choices.size(),
			"portal_submitted": _portal_choices.has(player_id),
		})
	return view


func _start_encounter(definition: EncounterData) -> void:
	active_encounter = definition.duplicate()
	active_encounter.player_max_hp = _data.player_max_hp
	active_encounter.shuffle_seed = _rng.randi()
	active_combat = CombatState.new(active_encounter, active_encounter.shuffle_seed,
		_player_ids, -1, _decks, _current_hps, _arcana_choices)
	_reward_ready = 0
	_portal_choices.clear()
	encounter_id += 1
