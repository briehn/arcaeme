extends RefCounted

const SAMPLE_COUNT := 24
const MIN_STROKE_LENGTH_RATIO := 0.55
const MAX_STROKE_LENGTH_RATIO := 1.60


## A score of zero rejects the cast. Positive scores indicate a match, with one exact.
static func recognize(template_strokes: Array[PackedVector2Array], drawn_strokes: Array[PackedVector2Array],
		min_extent: float, tolerance: float) -> float:
	if (template_strokes.is_empty() or drawn_strokes.size() != template_strokes.size()
			or not is_finite(tolerance) or tolerance <= 0.0
			or not is_finite(min_extent) or min_extent < 0.0):
		return 0.0
	var template_bounds := _bounds(template_strokes)
	var drawing_bounds := _bounds(drawn_strokes)
	var template_extent := _extent(template_bounds)
	var drawing_extent := _extent(drawing_bounds)
	if (is_zero_approx(template_extent) or is_zero_approx(drawing_extent)
			or drawing_extent < min_extent):
		return 0.0

	var error := 0.0
	for index in template_strokes.size():
		var template_path := template_strokes[index]
		var drawn_path := drawn_strokes[index]
		var template_distances := _distances(template_path)
		var drawn_distances := _distances(drawn_path)
		var template_length := template_distances[-1] / template_extent
		var drawn_length := drawn_distances[-1] / drawing_extent
		if is_zero_approx(template_length):
			return 0.0
		var length_ratio := drawn_length / template_length
		if length_ratio < MIN_STROKE_LENGTH_RATIO or length_ratio > MAX_STROKE_LENGTH_RATIO:
			return 0.0
		# Check each directed stroke independently so a small bad stroke cannot hide in the average.
		var expected := _sample(template_path, template_distances, template_bounds)
		var actual := _sample(drawn_path, drawn_distances, drawing_bounds)
		var stroke_error := _path_error(expected, actual)
		if stroke_error >= tolerance:
			return 0.0
		error = maxf(error, stroke_error)
	return 1.0 - error / tolerance


static func _bounds(strokes: Array[PackedVector2Array]) -> Rect2:
	var bounds := Rect2(strokes[0][0], Vector2.ZERO) if not strokes[0].is_empty() else Rect2()
	for stroke in strokes:
		if stroke.size() < 2:
			return Rect2()
		for point in stroke:
			if not point.is_finite() or point.x < 0.0 or point.x > 1.0 or point.y < 0.0 or point.y > 1.0:
				return Rect2()
			bounds = bounds.expand(point)
	return bounds


static func _extent(bounds: Rect2) -> float:
	return maxf(bounds.size.x, bounds.size.y)


static func _distances(stroke: PackedVector2Array) -> PackedFloat32Array:
	var distances := PackedFloat32Array()
	distances.resize(stroke.size())
	for index in range(1, stroke.size()):
		distances[index] = distances[index - 1] + stroke[index - 1].distance_to(stroke[index])
	return distances


## Resample at equal distances along the path so event density does not affect the result.
static func _sample(stroke: PackedVector2Array, distances: PackedFloat32Array,
		bounds: Rect2) -> PackedVector2Array:
	var length := distances[-1]
	var center := bounds.get_center()
	var extent := _extent(bounds)
	var sampled := PackedVector2Array()
	sampled.append((stroke[0] - center) / extent)
	var segment := 1
	for index in range(1, SAMPLE_COUNT - 1):
		var distance := length * index / float(SAMPLE_COUNT - 1)
		while distances[segment] <= distance:
			segment += 1
		var fraction := inverse_lerp(distances[segment - 1], distances[segment], distance)
		var point := stroke[segment - 1].lerp(stroke[segment], fraction)
		sampled.append((point - center) / extent)
	sampled.append((stroke[-1] - center) / extent)
	return sampled


static func _path_error(expected: PackedVector2Array, drawn: PackedVector2Array) -> float:
	var squared_error := 0.0
	for index in SAMPLE_COUNT:
		squared_error += expected[index].distance_squared_to(drawn[index])
	var start_error := expected[0].distance_to(drawn[0])
	var end_error := expected[SAMPLE_COUNT - 1].distance_to(drawn[SAMPLE_COUNT - 1])
	return maxf(sqrt(squared_error / SAMPLE_COUNT), maxf(start_error, end_error) * 0.75)
