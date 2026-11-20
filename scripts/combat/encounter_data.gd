extends Resource

const CardData = preload("res://scripts/combat/card_data.gd")
const EnemyAction = preload("res://scripts/combat/enemy_action.gd")

@export_group("Provisional Playtest Fixture")
@export var player_max_hp: int
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
