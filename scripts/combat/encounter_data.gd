extends Resource

const CardData = preload("res://scripts/combat/card_data.gd")

@export_group("Provisional Playtest Fixture")
@export var player_max_hp: int
@export var enemy_id: StringName
@export var enemy_name: String
@export var enemy_max_hp: int
@export var enemy_attack: int
@export var shuffle_seed: int
@export var test_deck: Array[CardData] = []
## Provisional attack payloads applied to living targets after direct damage.
@export var enemy_poison_per_attack: int
@export var enemy_burning_per_attack: int
@export var enemy_starting_strength: int
@export var enemy_starting_dexterity: int
