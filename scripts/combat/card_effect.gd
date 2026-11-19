extends Resource

enum Kind { DAMAGE, GAIN_BLOCK, DRAW, PREPARE_ATTACK, APPLY_POISON, APPLY_BURNING }

@export var kind: Kind
@export var amount: int
## Damage effects with a positive divisor gain one damage for each full group of Block.
@export var block_per_bonus: int
## A positive cost enables automatic spending for the conditional bonus damage.
@export var block_to_spend: int
@export var damage_on_block_spend: int


func targets_enemy() -> bool:
	return kind in [Kind.DAMAGE, Kind.APPLY_POISON, Kind.APPLY_BURNING]


func describe() -> String:
	match kind:
		Kind.DAMAGE:
			var description := "Deal %d damage." % amount
			if block_per_bonus > 0:
				description += " Deal 1 additional damage for every %d Block you currently have." % block_per_bonus
			if block_to_spend > 0:
				description += " If you have at least %d Block, lose %d Block to deal %d additional damage." % [
					block_to_spend, block_to_spend, damage_on_block_spend]
			return description
		Kind.GAIN_BLOCK:
			return "Gain %d Block." % amount
		Kind.DRAW:
			return "Draw %d %s." % [amount, "card" if amount == 1 else "cards"]
		Kind.PREPARE_ATTACK:
			return "Your next Attack this turn deals %d additional damage." % amount
		Kind.APPLY_POISON:
			return "Apply %d Poison." % amount
		Kind.APPLY_BURNING:
			return "Apply %d Burning." % amount
	return ""
