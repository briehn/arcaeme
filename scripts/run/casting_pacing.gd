extends RefCounted

var encounters: Dictionary[int, Dictionary] = {}
var totals: Dictionary
var _seat_count: int


func _init(seat_count: int) -> void:
	_seat_count = seat_count
	totals = _new_counts()


func begin_encounter(index: int) -> void:
	encounters[index] = _new_counts()


func prompt_opened(index: int) -> void:
	totals.prompts += 1
	encounters[index].prompts += 1


func attempt_finished(seat: int, quality: String, reason: String, elapsed_ms: int, index: int) -> void:
	_update_counts(totals, seat, quality, reason, elapsed_ms)
	_update_counts(encounters[index], seat, quality, reason, elapsed_ms)


func tooltip() -> String:
	if encounters.is_empty():
		return ""
	var lines := PackedStringArray(["Casting pacing (debug)", _format_counts("Run", totals)])
	for index in encounters:
		lines.append(_format_counts("Encounter %d" % index, encounters[index]))
	return "\n".join(lines)


func _new_counts() -> Dictionary:
	var casts_by_seat: Dictionary[int, int] = {}
	for seat in range(1, _seat_count + 1):
		casts_by_seat[seat] = 0
	return {"prompts": 0, "successful": 0, "faint": 0, "excellent": 0, "canceled": 0,
		"expired": 0, "drawing_ms": 0, "casts_by_seat": casts_by_seat}


static func _update_counts(counts: Dictionary, seat: int, quality: String, reason: String, elapsed_ms: int) -> void:
	counts.drawing_ms += elapsed_ms
	counts.canceled += int(reason == "canceled")
	counts.expired += int(reason == "expired")
	if not quality.is_empty():
		counts.successful += 1
		counts.faint += int(quality == "Faint")
		counts.excellent += int(quality == "Excellent")
		counts.casts_by_seat[seat] = counts.casts_by_seat.get(seat, 0) + 1


static func _format_counts(label: String, counts: Dictionary) -> String:
	var seats := PackedStringArray()
	for seat: int in counts.casts_by_seat:
		seats.append("Mage %d: %d" % [seat, counts.casts_by_seat[seat]])
	var line := "%s · %d prompts · %d cast · %d faint · %d excellent · %d canceled · %d expired · %.1f s" % [
		label, counts.prompts, counts.successful, counts.faint, counts.excellent, counts.canceled,
		counts.expired, counts.drawing_ms / 1000.0]
	if not seats.is_empty():
		line += "\n  " + " · ".join(seats)
	return line
