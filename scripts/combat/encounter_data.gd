extends Resource

enum Category { NORMAL, ELITE, BOSS }

@export var category := Category.NORMAL

const CardData = preload("res://scripts/combat/card_data.gd")
const EnemyAction = preload("res://scripts/combat/enemy_action.gd")
const EnemyData = preload("res://scripts/combat/enemy_data.gd")

@export_group("Provisional Playtest Fixture")
@export var player_max_hp: int
## When set, these enemies act in array order. Empty uses the existing single-enemy fields.
@export var enemies: Array[EnemyData] = []
@export var enemy_id: StringName
@export var enemy_name: String
@export var enemy_max_hp: int
@export var enemy_attack: int
## Optional nonnegative base attacks, repeating from round one. Empty uses enemy_attack.
@export var enemy_attack_pattern: PackedInt32Array
## Optional action cycle, repeating from round one. Empty uses the attack-only settings.
@export var action_cycle: Array[EnemyAction] = []
@export var shuffle_seed: int
@export var test_deck: Array[CardData] = []
## Provisional attack payloads applied to living targets after direct damage.
@export var enemy_poison_per_attack: int
@export var enemy_burning_per_attack: int
@export var enemy_starting_strength: int
@export var enemy_starting_dexterity: int


func legacy_enemy_data() -> EnemyData:
	var enemy := EnemyData.new()
	enemy.id = enemy_id
	enemy.display_name = enemy_name
	enemy.max_hp = enemy_max_hp
	enemy.attack = enemy_attack
	enemy.attack_pattern = enemy_attack_pattern
	enemy.action_cycle = action_cycle
	enemy.poison_per_attack = enemy_poison_per_attack
	enemy.burning_per_attack = enemy_burning_per_attack
	enemy.starting_strength = enemy_starting_strength
	enemy.starting_dexterity = enemy_starting_dexterity
	return enemy
