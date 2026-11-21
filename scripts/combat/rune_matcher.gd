extends RefCounted

const SAMPLE_COUNT := 24
const MIN_STROKE_LENGTH_RATIO := 0.55
const MAX_STROKE_LENGTH_RATIO := 1.60
const MIN_PRIMARY_BEND := 0.12
const MIN_SECOND_TURN := 0.10
const DUPLICATE_ERROR := 0.06
const PARTIAL_FRACTIONS := [0.60, 0.70, 0.80, 0.90]
const PARTIAL_SCORE_MARGIN := 0.08
const LOOP_STARTS := 8

enum Contour { STRAIGHT_OR_CURVED, BENT, LOOP }

class MatchResult:
	var score: float
	var complete: bool

	func _init(match_score: float, is_complete: bool) -> void:
		score = match_score
		complete = is_complete


class PathProfile:
	var samples: PackedVector2Array
	var length: float
	var bend: float
	var closed: bool
	var multiple_turns: bool


## Null rejects the drawing. Only the existing Booster fallback may omit one failed stroke.
static func recognize(template_strokes: Array[PackedVector2Array], drawn_strokes: Array[PackedVector2Array],
		min_extent: float, tolerance: float, min_coverage: float, allow_failed_augmentation := false) -> MatchResult:
	if (drawn_strokes.is_empty() or template_strokes.is_empty() or not is_finite(tolerance) or tolerance <= 0.0
			or drawn_strokes.size() > template_strokes.size() + int(allow_failed_augmentation)):
		return null
	var drawn := _profiles(drawn_strokes, min_extent)
	if drawn.is_empty() or _has_duplicate(drawn):
		return null
	if drawn.size() <= template_strokes.size():
		return _recognize_components(template_strokes, drawn, tolerance, min_coverage)

	# The failed augmentation may be anywhere in the input, so try each possible omission.
	var best: MatchResult
	for omitted in drawn_strokes.size():
		var candidate := drawn_strokes.duplicate()
		candidate.remove_at(omitted)
		var remaining := _profiles(candidate, min_extent)
		if remaining.is_empty():
			continue
		var result := _recognize_components(template_strokes, remaining, tolerance, min_coverage)
		if result != null and (best == null or result.score > best.score):
			best = result
	return best


static func _recognize_components(template_strokes: Array[PackedVector2Array], drawn: Array[PathProfile],
		tolerance: float, min_coverage: float) -> MatchResult:
	var lengths: Array[PackedFloat32Array] = []
	var contours: Array[Contour] = []
	var guide_length := 0.0
	for stroke in template_strokes:
		if stroke.size() < 2:
			return null
		var distances := _distances(stroke)
		if is_zero_approx(distances[-1]):
			return null
		lengths.append(distances)
		if stroke[0].is_equal_approx(stroke[-1]):
			contours.append(Contour.LOOP)
		else:
			contours.append(Contour.BENT if _normalized_bend(stroke) >= MIN_PRIMARY_BEND else Contour.STRAIGHT_OR_CURVED)
		guide_length += distances[-1]

	var full_score := 0.0
	if drawn.size() == template_strokes.size():
		full_score = _match_score(template_strokes, contours, drawn, tolerance)
		if is_equal_approx(full_score, 1.0):
			return MatchResult.new(full_score, true)

	var partial_score := 0.0
	# The prototype has at most three components. Try subsets and shorten at most one component.
	for mask in range(1, 1 << template_strokes.size()):
		var subset: Array[PackedVector2Array] = []
		var subset_contours: Array[Contour] = []
		var indices: Array[int] = []
		var subset_length := 0.0
		for index in template_strokes.size():
			if mask & (1 << index):
				indices.append(index)
				subset.append(template_strokes[index])
				subset_contours.append(contours[index])
				subset_length += lengths[index][-1]
		if subset.size() != drawn.size() or subset_length < guide_length * min_coverage - 0.00001:
			continue
		if subset.size() < template_strokes.size():
			partial_score = maxf(partial_score, _match_score(subset, subset_contours, drawn, tolerance))
		for slot in subset.size():
			var original := template_strokes[indices[slot]]
			var distances := lengths[indices[slot]]
			var is_loop := original[0].is_equal_approx(original[-1])
			for fraction: float in PARTIAL_FRACTIONS:
				var kept_length := distances[-1] * fraction
				if subset_length - distances[-1] + kept_length < guide_length * min_coverage - 0.00001:
					continue
				# Open paths can be started at either end. Loop cuts offer several starting points.
				var starts := LOOP_STARTS if is_loop else 2
				for start in starts:
					var offset := distances[-1] * start / starts if is_loop else (distances[-1] - kept_length) * start
					subset[slot] = _path_section(original, distances, offset, offset + kept_length)
					partial_score = maxf(partial_score, _match_score(subset, subset_contours, drawn, tolerance))
			subset[slot] = original
	if partial_score > 0.0 and (full_score <= 0.0 or partial_score > full_score + PARTIAL_SCORE_MARGIN):
		return MatchResult.new(partial_score, false)
	return MatchResult.new(full_score, true) if full_score > 0.0 else null


static func _match_score(template: Array[PackedVector2Array], contours: Array[Contour],
		drawn: Array[PathProfile], tolerance: float) -> float:
	var expected := _profiles(template, 0.0)
	if expected.is_empty():
		return 0.0
	var scores: Array[PackedFloat64Array] = []
	for slot in expected.size():
		var row := PackedFloat64Array()
		for actual in drawn:
			var ratio := actual.length / expected[slot].length
			var shape_matches := (contours[slot] != Contour.BENT or actual.bend >= MIN_PRIMARY_BEND) \
				and (contours[slot] != Contour.LOOP or actual.multiple_turns)
			if ratio < MIN_STROKE_LENGTH_RATIO or ratio > MAX_STROKE_LENGTH_RATIO or not shape_matches:
				row.append(0.0)
			else:
				row.append(maxf(0.0, 1.0 - _stroke_error(expected[slot], actual) / tolerance))
		scores.append(row)
	return _best_assignment(scores, 0, 0)


static func _best_assignment(scores: Array[PackedFloat64Array], slot: int, used: int) -> float:
	if slot == scores.size():
		return 1.0
	var best := 0.0
	for index in scores[slot].size():
		var bit := 1 << index
		if not (used & bit) and scores[slot][index] > best:
			best = maxf(best, minf(scores[slot][index], _best_assignment(scores, slot + 1, used | bit)))
	return best


static func _has_duplicate(drawn: Array[PathProfile]) -> bool:
	for first in drawn.size():
		for second in range(first + 1, drawn.size()):
			var ratio := drawn[first].length / drawn[second].length
			if ratio < 0.85 or ratio > 1.0 / 0.85:
				continue
			var error := _stroke_error(drawn[first], drawn[second])
			var a := drawn[first].samples
			var b := drawn[second].samples
			if a[0].distance_to(a[-1]) < DUPLICATE_ERROR and b[0].distance_to(b[-1]) < DUPLICATE_ERROR:
				error = minf(error, _loop_error(a, b))
			if error < DUPLICATE_ERROR:
				return true
	return false


static func _profiles(strokes: Array[PackedVector2Array], min_extent: float) -> Array[PathProfile]:
	var bounds := _bounds(strokes)
	var extent := _extent(bounds)
	if is_zero_approx(extent) or extent < min_extent:
		return []
	var profiles: Array[PathProfile] = []
	for stroke in strokes:
		var distances := _distances(stroke)
		if is_zero_approx(distances[-1]):
			return []
		var profile := PathProfile.new()
		profile.samples = _sample(stroke, distances, bounds)
		profile.length = distances[-1] / extent
		profile.bend = _normalized_bend(stroke)
		profile.closed = stroke[0].is_equal_approx(stroke[-1])
		profile.multiple_turns = _has_multiple_turns(profile.samples)
		profiles.append(profile)
	return profiles


static func _has_multiple_turns(path: PackedVector2Array) -> bool:
	# A single corner can resemble part of Salvo's outline after scaling. Keep a second turn.
	var split := 0
	var greatest_gap := 0.0
	for index in range(1, path.size() - 1):
		var point := path[index]
		var gap := point.distance_squared_to(Geometry2D.get_closest_point_to_segment(point, path[0], path[-1]))
		if gap > greatest_gap:
			greatest_gap = gap
			split = index
	if greatest_gap < MIN_SECOND_TURN * MIN_SECOND_TURN:
		return false
	for index in range(1, path.size() - 1):
		var point := path[index]
		var first := path[0] if index < split else path[split]
		var last := path[split] if index < split else path[-1]
		if point.distance_squared_to(Geometry2D.get_closest_point_to_segment(point, first, last)) >= MIN_SECOND_TURN * MIN_SECOND_TURN:
			return true
	return false


static func _normalized_bend(stroke: PackedVector2Array) -> float:
	var extent := _extent(_bounds([stroke]))
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


static func _path_section(stroke: PackedVector2Array, distances: PackedFloat32Array,
		start: float, finish: float) -> PackedVector2Array:
	var length := distances[-1]
	var section := PackedVector2Array([_point_at(stroke, distances, start)])
	for index in range(1, stroke.size() - 1):
		if distances[index] > start and distances[index] < finish:
			section.append(stroke[index])
	if finish <= length:
		section.append(_point_at(stroke, distances, finish))
	else:
		section.append(stroke[-1])
		var remainder := _path_section(stroke, distances, 0.0, finish - length)
		section.append_array(remainder.slice(1))
	return section


static func _point_at(stroke: PackedVector2Array, distances: PackedFloat32Array, distance: float) -> Vector2:
	if distance >= distances[-1]:
		return stroke[-1]
	var segment := 1
	while distances[segment] <= distance:
		segment += 1
	var fraction := inverse_lerp(distances[segment - 1], distances[segment], distance)
	return stroke[segment - 1].lerp(stroke[segment], fraction)


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


static func _stroke_error(expected: PathProfile, actual: PathProfile) -> float:
	var forward := _path_error(expected.samples, actual.samples, false)
	var reverse := _path_error(expected.samples, actual.samples, true)
	var best := minf(forward, reverse)
	if expected.closed:
		best = minf(best, _loop_error(expected.samples, actual.samples))
	return best


static func _path_error(expected: PackedVector2Array, drawn: PackedVector2Array, reverse: bool) -> float:
	var squared_error := 0.0
	for index in SAMPLE_COUNT:
		var actual_index := SAMPLE_COUNT - 1 - index if reverse else index
		squared_error += expected[index].distance_squared_to(drawn[actual_index])
	var start_error := expected[0].distance_to(drawn[-1] if reverse else drawn[0])
	var end_error := expected[-1].distance_to(drawn[0] if reverse else drawn[-1])
	return maxf(sqrt(squared_error / SAMPLE_COUNT), maxf(start_error, end_error) * 0.45)


static func _loop_error(expected: PackedVector2Array, drawn: PackedVector2Array) -> float:
	var best := INF
	var points := SAMPLE_COUNT - 1 # Omit the repeated endpoint when shifting the loop.
	for direction in [-1, 1]:
		for start in points:
			var squared_error := 0.0
			var projected := 0.0
			var span_squared := 0.0
			for index in points:
				var anchor := expected[posmod(start + index * direction, points)]
				var span := expected[posmod(start + (index + 1) * direction, points)] - anchor
				var offset := drawn[index] - anchor
				squared_error += offset.length_squared()
				projected += offset.dot(span)
				span_squared += span.length_squared()
			# Fit a fractional shift as well so starting between sample points is not penalized.
			var phase := clampf(projected / span_squared, 0.0, 1.0) if span_squared > 0.0 else 0.0
			var shifted_error := squared_error - 2.0 * phase * projected + phase * phase * span_squared
			best = minf(best, sqrt(maxf(0.0, shifted_error) / points))
	return maxf(best, drawn[0].distance_to(drawn[-1]) * 0.45)
