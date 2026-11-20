extends Resource

const EnemyAction = preload("res://scripts/combat/enemy_action.gd")

## Unique within this encounter. The same species can occupy several slots.
@export var id: StringName
@export var display_name: String
@export var max_hp: int
@export var attack: int
## Used when there is no action cycle. Empty uses attack.
@export var attack_pattern: PackedInt32Array
@export var action_cycle: Array[EnemyAction] = []
@export var poison_per_attack: int
@export var burning_per_attack: int
@export var starting_strength: int
@export var starting_dexterity: int
