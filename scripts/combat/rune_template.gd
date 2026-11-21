extends Resource

@export var display_name: String
## Rune components in a normalized square. Either tracing direction is valid.
@export var strokes: Array[PackedVector2Array] = []
## A connected extra component displayed when a Booster is primed.
@export var booster_stroke := PackedVector2Array()
@export var cast_time_ms: int = 10000
