extends RefCounted

const CardData = preload("res://scripts/combat/card_data.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const RunData = preload("res://scripts/run/run_data.gd")

enum Stage { ROUTE, OPENING_COMBAT, REWARD, BOSS_READY, BOSS_COMBAT, VICTORY, DEFEAT }

const PLAYER_ID := &"Battle Mage"
const PLAYER_CLASS := RunData.BATTLE_MAGE

var stage := Stage.ROUTE
var run_seed: int
var max_hp: int
var current_hp: int
var active_encounter: EncounterData
var active_combat: CombatState
var selected_reward: CardData

var _data: RunData
var _deck: Array[CardData]
var _eligible_rewards: Array[CardData] = []
var _rng := RandomNumberGenerator.new()


func _init(data: RunData) -> void:
	_data = data
	run_seed = data.run_seed
	_rng.seed = run_seed
	max_hp = data.player_max_hp
	current_hp = max_hp
	_deck = data.starting_deck.duplicate()
	_eligible_rewards = data.eligible_rewards(PLAYER_CLASS)


func deck_cards() -> Array[CardData]:
	return _deck.duplicate()


func reward_options() -> Array[CardData]:
	return _eligible_rewards.duplicate() if stage == Stage.REWARD else []


func choose_opening(encounter_id: StringName) -> bool:
	if stage != Stage.ROUTE:
		return false
	for encounter in _data.opening_encounters:
		if encounter.enemy_id == encounter_id:
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
	elif stage == Stage.OPENING_COMBAT:
		stage = Stage.REWARD
	else:
		stage = Stage.VICTORY
	return true


func take_reward(card_id: StringName) -> bool:
	if stage != Stage.REWARD:
		return false
	for card in _eligible_rewards:
		if card.id == card_id:
			_deck.append(card)
			selected_reward = card
			stage = Stage.BOSS_READY
			return true
	return false


func skip_reward() -> bool:
	if stage != Stage.REWARD:
		return false
	stage = Stage.BOSS_READY
	return true


func start_boss() -> bool:
	if stage != Stage.BOSS_READY:
		return false
	_start_combat(_data.boss_encounter, Stage.BOSS_COMBAT)
	return true


func _start_combat(definition: EncounterData, next_stage: Stage) -> void:
	# Combat owns its piles and modifiers. Only current HP and the run deck cross this boundary.
	active_encounter = definition.duplicate()
	active_encounter.player_max_hp = max_hp
	active_encounter.test_deck = _deck.duplicate()
	active_encounter.shuffle_seed = _rng.randi()
	active_combat = CombatState.new(active_encounter, active_encounter.shuffle_seed, [PLAYER_ID], current_hp)
	stage = next_stage
