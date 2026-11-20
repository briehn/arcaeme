extends RefCounted

const RunData = preload("res://scripts/run/run_data.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")

enum VariantKind { BASELINE, TIMING, DURABILITY, COMBINED }

const LABELS := ["Baseline", "Earlier Attacks (Provisional)", "Extra Enemy HP (Provisional)",
	"Earlier Attacks + Extra HP (Provisional)"]
const EXTRA_HP := {2: 10, 3: 18, 4: 26}


static func available_variants() -> Array[VariantKind]:
	return [VariantKind.BASELINE, VariantKind.TIMING, VariantKind.DURABILITY, VariantKind.COMBINED]


static func label_for(variant: VariantKind) -> String:
	return LABELS[variant]


static func make_run(template: RunData, variant: VariantKind, party_size: int) -> RunData:
	if variant == VariantKind.BASELINE:
		return template
	var earlier := variant == VariantKind.TIMING or variant == VariantKind.COMBINED
	var extra_hp: int = EXTRA_HP.get(party_size, 0) if variant in [VariantKind.DURABILITY, VariantKind.COMBINED] else 0
	var run: RunData = template.duplicate()
	run.title = "%s / %s" % [template.title, label_for(variant)]
	var openings: Array[EncounterData] = []
	for encounter in template.opening_encounters:
		openings.append(_adjust_encounter(encounter, earlier, extra_hp))
	run.opening_encounters = openings
	run.boss_encounter = _adjust_encounter(template.boss_encounter, earlier, extra_hp)
	return run


static func _adjust_encounter(encounter: EncounterData, earlier: bool, extra_hp: int) -> EncounterData:
	if encounter.enemy_id not in [&"goblin", &"treant"]:
		return encounter
	var fixture: EncounterData = encounter.duplicate()
	fixture.enemy_max_hp += extra_hp
	if earlier:
		if fixture.enemy_id == &"goblin":
			fixture.enemy_attack_pattern = PackedInt32Array([14, 7, 14])
		else:
			fixture.enemy_attack_pattern = PackedInt32Array([10, 4, 4])
	return fixture
