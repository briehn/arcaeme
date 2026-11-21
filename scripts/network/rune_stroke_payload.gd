extends RefCounted

const MAX_STROKES := 8
const MAX_STROKE_POINTS := 1024
const MAX_TOTAL_POINTS := 2048
const POINT_BYTES := 8
const MAX_BYTES := 1 + MAX_STROKES * 2 + MAX_TOTAL_POINTS * POINT_BYTES


static func encode(strokes: Array[PackedVector2Array]) -> PackedByteArray:
	var payload := PackedByteArray()
	if strokes.size() > MAX_STROKES:
		return payload
	var total := 0
	for stroke in strokes:
		if stroke.is_empty() or stroke.size() > MAX_STROKE_POINTS:
			return payload
		total += stroke.size()
	if total > MAX_TOTAL_POINTS:
		return payload
	payload.resize(1 + strokes.size() * 2 + total * POINT_BYTES)
	payload[0] = strokes.size()
	var offset := 1
	for stroke in strokes:
		payload.encode_u16(offset, stroke.size())
		offset += 2
		for point in stroke:
			payload.encode_float(offset, point.x)
			payload.encode_float(offset + 4, point.y)
			offset += POINT_BYTES
	return payload


## Null denotes malformed data. An empty array is a valid attempt with no ink.
static func decode(payload: PackedByteArray) -> Variant:
	if payload.is_empty() or payload.size() > MAX_BYTES or payload[0] > MAX_STROKES:
		return null
	var strokes: Array[PackedVector2Array] = []
	var offset := 1
	var total := 0
	for _index in payload[0]:
		if offset + 2 > payload.size():
			return null
		var count := payload.decode_u16(offset)
		offset += 2
		total += count
		if count == 0 or count > MAX_STROKE_POINTS or total > MAX_TOTAL_POINTS \
				or offset + count * POINT_BYTES > payload.size():
			return null
		var stroke := PackedVector2Array()
		for _point in count:
			var point := Vector2(payload.decode_float(offset), payload.decode_float(offset + 4))
			if not point.is_finite() or point != point.clamp(Vector2.ZERO, Vector2.ONE):
				return null
			stroke.append(point)
			offset += POINT_BYTES
		strokes.append(stroke)
	return strokes if offset == payload.size() else null
