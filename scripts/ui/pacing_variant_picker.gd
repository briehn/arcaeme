extends OptionButton

const PacingExperiment = preload("res://scripts/run/pacing_experiment.gd")

@export var solo_setup := false


func _ready() -> void:
	for variant in PacingExperiment.available_variants():
		if solo_setup and variant not in [PacingExperiment.VariantKind.BASELINE, PacingExperiment.VariantKind.TIMING]:
			continue
		add_item(PacingExperiment.label_for(variant), variant)
	select(get_item_index(PacingExperiment.VariantKind.BASELINE))


func selected_variant() -> PacingExperiment.VariantKind:
	return get_selected_id() as PacingExperiment.VariantKind
