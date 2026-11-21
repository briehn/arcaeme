extends Resource

@export var display_name: String
## Ordered, directed paths in a normalized square.
@export var strokes: Array[PackedVector2Array] = []
## A connected extra stroke appended after the ordinary guide.
@export var booster_stroke := PackedVector2Array()
@export var cast_time_ms: int = 10000
