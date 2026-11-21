extends SceneTree

const Pool = preload("res://scripts/run/battle_mage_pool_playtest.gd")
const CombatState = preload("res://scripts/combat/combat_state.gd")
const RunView = preload("res://scripts/prototype_run.gd")
const REQUIRED_ASSETS := [
	"res://assets/branding/Arcaeme_Main_logo.png",
	"res://assets/branding/Arcaeme_Icon.png",
	"res://assets/portals/portal_normal.png",
	"res://assets/portals/portal_elite.png",
	"res://assets/portals/portal_boss.png",
	"res://scenes/combat.tscn",
	"res://scenes/encounter_reward_overlay.tscn",
	"res://scenes/spell_drawing_panel.tscn",
	"res://resources/prototype/encounter_backdrop.tres",
	"res://resources/prototype/enemies/two_slimes.tres",
	"res://resources/prototype/enemies/citadel_warden.tres",
]

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_check(OS.has_feature("arcaeme_alpha"), "the pack carries the curated alpha feature")
	for path in REQUIRED_ASSETS:
		_check(ResourceLoader.exists(path) and load(path) != null, "pack loads " + path)
	var icon := String(ProjectSettings.get_setting("application/config/icon"))
	_check(ResourceLoader.exists(icon), "the configured game icon resolves")
	var catalogue := Pool.catalogue()
	_check(catalogue.size() == 24, "the Battle Mage catalogue contains 24 regular cards")
	for card in catalogue:
		_check(card != null and card.rune_template != null and not card.rune_template.strokes.is_empty(),
			"a packaged Battle Mage card loads its rune resource")
	for directory in ["docs", ".codex", "tests", "tools"]:
		_check(not DirAccess.dir_exists_absolute("res://" + directory), "excluded pack directory " + directory)
	_check(not FileAccess.file_exists("res://AGENTS.md"), "private root guidance is absent")
	if _failures == 0:
		await _check_launch()
	var arguments := OS.get_cmdline_user_args()
	if _failures == 0 and not arguments.is_empty():
		_write_engine_notices(arguments[0])
	print("Windows alpha pack: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _check_launch() -> void:
	var main_scene := String(ProjectSettings.get_setting("application/run/main_scene"))
	if not _check(change_scene_to_file(main_scene) == OK, "launch the configured main scene"):
		return
	await scene_changed
	var menu := current_scene
	var start := menu.get_node("%StartAlphaRun") as Button
	var version := String(ProjectSettings.get_setting("application/config/version"))
	_check(start.is_visible_in_tree() and not (menu.get_node("%PrimaryNavigation") as Control).visible
		and not (menu.get_node("%PrototypeNavigation") as Control).visible,
		"only the player-facing navigation is exposed")
	_check(not version.is_empty() and version in (menu.get_node("%AlphaBuild") as Label).text, "show the build ID")
	start.pressed.emit()
	await scene_changed
	var run := current_scene as RunView
	if not _check(run != null and run.run_data.portal_enabled and run.spell_drawing != null
			and not run.bypass_drawing and not run.local_coop, "the solo portal run requires drawing"):
		return
	(run.get_node("%Choices").get_child(0) as Button).pressed.emit()
	await process_frame
	var combat := run.get_node_or_null("Combat")
	if not _check(combat != null, "the opening encounter starts"):
		return
	var state := combat._state as CombatState
	_check(state.enemies.size() == 2 and state.round_number == 1, "the run opens against Two Slimes")
	for copy: int in state.players.values()[0].hand:
		var card := state.card_data(copy)
		if card.targets_enemy() and card.rune_template != null:
			combat._on_card_pressed(copy)
			combat._on_enemy_selected(state.enemies[1].id)
			_check(combat._spell_panel.is_visible_in_tree() and state.action_history.is_empty(),
				"card-first targeting opens the packaged workspace without spending the card")
			return
	_check(false, "the opening hand exposes an attack for the launch probe")


func _write_engine_notices(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not _check(file != null, "write Godot license and notices beside the package"):
		return
	file.store_line(Engine.get_license_text())
	for component: Dictionary in Engine.get_copyright_info():
		file.store_line("\n" + String(component.name))
		for part: Dictionary in component.parts:
			file.store_line("  " + ", ".join(part.copyright))
			file.store_line("  License: " + String(part.license))
	for license_name in Engine.get_license_info():
		file.store_line("\n%s\n%s" % [license_name, Engine.get_license_info()[license_name]])


func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)
	return condition
