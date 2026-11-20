extends Resource

enum Kind { ATTACK, BLOCK, GAIN_STRENGTH }

@export var kind: Kind
@export var amount: int
