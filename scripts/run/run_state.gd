extends RefCounted

const CardData = preload("res://scripts/combat/card_data.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const MajorArcana = preload("res://scripts/run/major_arcana.gd")
const PortalRoute = preload("res://scripts/run/portal_route.gd")
const RunData = preload("res://scripts/run/run_data.gd")

enum Stage {
	ROUTE, OPENING_COMBAT, REWARD, BOSS_READY, BOSS_COMBAT, VICTORY, DEFEAT,
	NEXT_READY, INTERMEDIATE_COMBAT, ARCANA, PORTAL,
}

const PLAYER_ID := &"Battle Mage"
const PLAYER_CLASS := RunData.BATTLE_MAGE

var stage := Stage.ROUTE
var run_seed: int
var max_hp: int
var current_hp: int
var encounter_id := 0
var active_encounter: EncounterData
var active_combat: CombatState
var selected_reward: CardData
var selected_arcana: StringName

var _data: RunData
var _deck: Array[CardData]
var _eligible_rewards: Array[CardData] = []
var _reward_choices: Array[StringName] = []
var _arcana_offers: Array[StringName] = []
var _rng := RandomNumberGenerator.new()
var _portal_route: PortalRoute


func _init(data: RunData) -> void:
	_data = data
	run_seed = data.run_seed
	_rng.seed = run_seed
	max_hp = data.player_max_hp
	current_hp = max_hp
	_deck = data.starting_deck.duplicate()
	_eligible_rewards = data.eligible_rewards(PLAYER_CLASS)
	if data.portal_enabled:
		_portal_route = PortalRoute.new(run_seed)
	if data.major_arcana_enabled:
		_arcana_offers = MajorArcana.offers(run_seed, 0, PLAYER_CLASS)
		stage = Stage.ARCANA


func arcana_options() -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	if stage == Stage.ARCANA:
		for id in _arcana_offers:
			options.append(MajorArcana.view(id))
	return options


func submit_arcana(id: StringName) -> bool:
	if stage != Stage.ARCANA or (id != &"" and id not in _arcana_offers):
		return false
	selected_arcana = id
	_arcana_offers.clear()
	stage = Stage.ROUTE
	return true


func deck_cards() -> Array[CardData]:
	return _deck.duplicate()


func reward_options() -> Array[CardData]:
	return _eligible_rewards.duplicate() if stage == Stage.REWARD else []


## Decisions in encounter order. An empty ID records a skip.
func reward_choices() -> Array[StringName]:
	return _reward_choices.duplicate()


func choose_opening(opening_id: StringName) -> bool:
	if stage != Stage.ROUTE:
		return false
	if _portal_route != null and opening_id != PortalRoute.START:
		return false
	for encounter in _data.opening_encounters:
		if encounter != null and encounter.enemy_id == opening_id:
			_start_combat(encounter, Stage.OPENING_COMBAT)
			return true
	return false


func finish_combat(combat: CombatState) -> bool:
	if combat == null or combat != active_combat:
		return false
	if combat.phase != CombatState.Phase.VICTORY and combat.phase != CombatState.Phase.DEFEAT:
		return false
	current_hp = combat.players[PLAYER_ID].hp
	active_combat = null
	if combat.phase == CombatState.Phase.DEFEAT:
		stage = Stage.DEFEAT
	elif stage == Stage.BOSS_COMBAT:
		stage = Stage.VICTORY
	else:
		selected_reward = null
		stage = Stage.REWARD
	return true


func take_reward(card_id: StringName) -> bool:
	if stage != Stage.REWARD:
		return false
	for card in _eligible_rewards:
		if card.id == card_id:
			_deck.append(card)
			_finish_reward(card)
			return true
	return false


func skip_reward() -> bool:
	if stage != Stage.REWARD:
		return false
	_finish_reward(null)
	return true


func start_boss() -> bool:
	return stage == Stage.BOSS_READY and start_next_encounter()


func next_encounter() -> EncounterData:
	if stage in [Stage.REWARD, Stage.NEXT_READY, Stage.BOSS_READY]:
		return _data.encounter_after(encounter_id)
	return null


func start_next_encounter() -> bool:
	if stage != Stage.NEXT_READY and stage != Stage.BOSS_READY:
		return false
	var definition := next_encounter()
	if definition == null:
		return false
	_start_combat(definition, Stage.BOSS_COMBAT if stage == Stage.BOSS_READY else Stage.INTERMEDIATE_COMBAT)
	return true


func portal_options() -> Array[Dictionary]:
	if stage != Stage.PORTAL:
		return []
	return _portal_route.options(active_encounter.enemy_id)


func submit_portal(id: StringName) -> bool:
	if stage != Stage.PORTAL:
		return false
	var destination := _portal_route.destination(active_encounter.enemy_id, id)
	if destination == null:
		return false
	_start_combat(destination,
		Stage.BOSS_COMBAT if destination.enemy_id == PortalRoute.BOSS else Stage.INTERMEDIATE_COMBAT)
	return true


func _finish_reward(card: CardData) -> void:
	selected_reward = card
	_reward_choices.append(card.id if card != null else &"")
	if _portal_route != null:
		stage = Stage.PORTAL
	else:
		stage = Stage.BOSS_READY if encounter_id + 1 == _data.encounter_count() else Stage.NEXT_READY


func _start_combat(definition: EncounterData, next_stage: Stage) -> void:
	# Combat owns its temporary state. The run carries HP, deck contents, and the Arcana choice.
	active_encounter = definition.duplicate()
	active_encounter.player_max_hp = max_hp
	active_encounter.test_deck = _deck.duplicate()
	active_encounter.shuffle_seed = _rng.randi()
	var arcana: Dictionary[StringName, StringName] = {PLAYER_ID: selected_arcana}
	active_combat = CombatState.new(active_encounter, active_encounter.shuffle_seed,
		[PLAYER_ID], current_hp, {}, {}, arcana)
	encounter_id += 1
	stage = next_stage
