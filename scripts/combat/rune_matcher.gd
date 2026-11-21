extends RefCounted

const SAMPLE_COUNT := 24
const MIN_STROKE_LENGTH_RATIO := 0.55
const MAX_STROKE_LENGTH_RATIO := 1.60
const MIN_PRIMARY_BEND := 0.12
const PREFIX_FRACTIONS := [0.60, 0.70, 0.80, 0.90, 1.00]
const PREFIX_SCORE_MARGIN := 0.08


class MatchResult:
	var score: float
	var complete: bool

	func _init(match_score: float, is_complete: bool) -> void:
		score = match_score
		complete = is_complete


## Null rejects the drawing. A recognizable prefix always resolves in the lowest quality tier.
static func recognize(template_strokes: Array[PackedVector2Array], drawn_strokes: Array[PackedVector2Array],
		min_extent: float, tolerance: float, min_coverage: float) -> MatchResult:
	if (drawn_strokes.is_empty() or drawn_strokes.size() > template_strokes.size()
			or not is_finite(tolerance) or tolerance <= 0.0):
		return null
	var drawing_bounds := _bounds(drawn_strokes)
	var drawing_extent := _extent(drawing_bounds)
	if is_zero_approx(drawing_extent) or drawing_extent < min_extent:
		return null
	# Even a generous fit cannot turn a straight swipe into a rune whose outline turns.
	var primary := template_strokes[0]
	if _normalized_bend(primary) >= MIN_PRIMARY_BEND and _normalized_bend(drawn_strokes[0]) < MIN_PRIMARY_BEND:
		return null

	var full_score := 0.0
	if drawn_strokes.size() == template_strokes.size():
		full_score = _match_score(template_strokes, drawn_strokes, drawing_bounds, tolerance)
	if is_equal_approx(full_score, 1.0):
		return MatchResult.new(full_score, true)

	var guide_length := 0.0
	for stroke in template_strokes:
		if stroke.size() < 2:
			return null
		guide_length += _distances(stroke)[-1]
	var final_index := drawn_strokes.size() - 1
	var prefix := template_strokes.slice(0, final_index)
	var prefix_length := 0.0
	for stroke in prefix:
		prefix_length += _distances(stroke)[-1]
	var last_stroke := template_strokes[final_index]
	var distances := _distances(last_stroke)
	var prefix_score := 0.0
	for fraction: float in PREFIX_FRACTIONS:
		if fraction == 1.0 and drawn_strokes.size() == template_strokes.size():
			continue
		var cutoff := distances[-1] * fraction
		if prefix_length + cutoff < guide_length * min_coverage - 0.00001:
			continue
		prefix.append(_cut_stroke(last_stroke, distances, cutoff))
		prefix_score = maxf(prefix_score, _match_score(prefix, drawn_strokes, drawing_bounds, tolerance))
		prefix.pop_back()
	if prefix_score > 0.0 and (full_score <= 0.0 or prefix_score > full_score + PREFIX_SCORE_MARGIN):
		return MatchResult.new(prefix_score, false)
	return MatchResult.new(full_score, true) if full_score > 0.0 else null


static func _match_score(template_strokes: Array[PackedVector2Array], drawn_strokes: Array[PackedVector2Array],
		drawing_bounds: Rect2, tolerance: float) -> float:
	var template_bounds := _bounds(template_strokes)
	var template_extent := _extent(template_bounds)
	var drawing_extent := _extent(drawing_bounds)
	if is_zero_approx(template_extent):
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


static func _normalized_bend(stroke: PackedVector2Array) -> float:
	if stroke.size() < 2:
		return 0.0
	var bounds := _bounds([stroke])
	var extent := _extent(bounds)
	if is_zero_approx(extent):
		return 0.0
	var chord := stroke[-1] - stroke[0]
	var direction := chord.normalized()
	var bend := 0.0
	for point in stroke:
		var offset := point - stroke[0]
		var gap := offset.length() if chord.length_squared() < 0.001 else absf(offset.cross(direction))
		bend = maxf(bend, gap)
	return bend / extent


static func _cut_stroke(stroke: PackedVector2Array, distances: PackedFloat32Array,
		cutoff: float) -> PackedVector2Array:
	if cutoff >= distances[-1]:
		return stroke
	var prefix := PackedVector2Array([stroke[0]])
	for index in range(1, stroke.size()):
		if distances[index] >= cutoff:
			var ratio := inverse_lerp(distances[index - 1], distances[index], cutoff)
			prefix.append(stroke[index - 1].lerp(stroke[index], ratio))
			break
		prefix.append(stroke[index])
	return prefix


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
	return maxf(sqrt(squared_error / SAMPLE_COUNT), maxf(start_error, end_error) * 0.45)
