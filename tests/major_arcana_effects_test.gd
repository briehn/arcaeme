extends SceneTree

const Arcana = preload("res://scripts/run/major_arcana.gd")
const Combat = preload("res://scripts/combat/combat_state.gd")
const Encounter = preload("res://scripts/combat/encounter_data.gd")
const Snapshot = preload("res://scripts/combat/combat_view_snapshot.gd")
const STRIKE = preload("res://resources/prototype/cards/basic_strike.tres")
const BLOCK = preload("res://resources/prototype/cards/basic_block.tres")
const SALVO = preload("res://resources/prototype/cards/expansion/astral_salvo.tres")
const REVERSAL = preload("res://resources/prototype/cards/arcane_reversal.tres")
const MAGE := &"Mage"
const ALLY := &"Ally"
const TARGET := &"target"

var _checks := 0
var _failures := 0
var _encounter: Encounter


func _initialize() -> void:
	_magician()
	_strength()
	_justice()
	_tower()
	print("Major Arcana effects: %d checks, %d failures." % [_checks, _failures])
	quit(int(_failures > 0))


func _combat(id: StringName, party := false) -> Combat:
	_encounter = Encounter.new()
	_encounter.enemy_id = TARGET
	_encounter.enemy_name = "Test enemy"
	_encounter.enemy_max_hp = 100
	_encounter.player_max_hp = 36
	_encounter.test_deck = [STRIKE, BLOCK, STRIKE, BLOCK, STRIKE, SALVO, REVERSAL]
	var roster: Array[StringName] = [MAGE]
	if party:
		roster.append(ALLY)
	var choices: Dictionary[StringName, StringName] = {MAGE: id}
	var combat := Combat.new(_encounter, 15, roster, -1, {}, {}, choices)
	combat.players[MAGE].hand.assign([0, 1, 2, 5, 6])
	combat.players[MAGE].draw_pile.assign([3, 4])
	return combat


func _magician() -> void:
	var combat := _combat(Arcana.MAGICIAN, true)
	var mage := combat.players[MAGE]
	_check(not combat.play_card(MAGE, 0, &"wrong") and not mage.arcana_saw_attack, "invalid attacks cannot count")
	_check(combat.play_card(MAGE, 0, TARGET) and mage.hand.size() == 4, "Attack alone grants no draw")
	_check(combat.end_turn(MAGE) and combat.undo_ready(MAGE) and mage.arcana_saw_attack,
		"Ready/Undo preserves progress without rerunning effects")
	_check(combat.play_card(MAGE, 1, &"") and mage.hand.size() == 4 and mage.arcana_used,
		"a non-Attack completes the pair and draws one")
	_check(combat.play_card(MAGE, 2, TARGET) and mage.hand.size() == 3, "pair triggers once per round")
	var own := Snapshot.build(combat, _encounter, MAGE)
	var ally := Snapshot.build(combat, _encounter, ALLY)
	_check(own.arcana.id == "the_magician" and not ally.has("arcana") and not ally.players[0].has("arcana"),
		"only the owner receives their Arcana progress")
	_check(combat.end_turn(MAGE) and combat.end_turn(ALLY) and not mage.arcana_used
		and not mage.arcana_saw_attack and not mage.arcana_saw_non_attack, "new round resets the pair")
	combat = _combat(Arcana.MAGICIAN)
	mage = combat.players[MAGE]
	mage.hand.assign([0, 1])
	mage.draw_pile.clear()
	combat.play_card(MAGE, 1, &"")
	_check(combat.play_card(MAGE, 0, TARGET) and mage.hand == [1] and mage.discard_pile == [0],
		"non-Attack first also works and reshuffle excludes the resolving Attack")


func _strength() -> void:
	var combat := _combat(Arcana.STRENGTH)
	var mage := combat.players[MAGE]
	mage.hand.assign([0, 2, 4])
	mage.draw_pile.assign([1, 3, 5, 6])
	for copy in [0, 2, 4]:
		_check(combat.play_card(MAGE, copy, TARGET), "play a qualifying Attack")
	_check(combat.enemy_hp == 82 and mage.strength == 1 and mage.arcana_attacks == 3,
		"third Attack resolves before the Strength gain")
	combat.end_turn(MAGE)
	mage.hand.assign([0])
	_check(combat.play_card(MAGE, 0, TARGET) and combat.enemy_hp == 75 and mage.strength == 1,
		"later Attack benefits from Strength without firing again")
	var fresh := _combat(Arcana.STRENGTH)
	_check(fresh.players[MAGE].arcana_attacks == 0 and fresh.players[MAGE].strength == 0
		and fresh.arcana_view(MAGE).id == "strength", "fresh combat keeps the Arcana and resets progress")


func _justice() -> void:
	var combat := _combat(Arcana.JUSTICE)
	var mage := combat.players[MAGE]
	mage.dexterity = 3
	_check(combat.play_card(MAGE, 0, TARGET) and not mage.arcana_used, "an Attack below threshold does not trigger")
	_check(combat.play_card(MAGE, 1, &"") and mage.block == 8, "card Block still benefits from Dexterity")
	_check(combat.play_card(MAGE, 6, TARGET) and mage.block == 6 and mage.arcana_used
		and combat.enemy_hp == 80, "Reversal spends Block first and Justice grants flat Block after damage")
	combat.end_turn(MAGE)
	_check(not mage.arcana_used and mage.block == 0, "Justice and ordinary Block expire on their usual boundaries")


func _tower() -> void:
	var combat := _combat(Arcana.TOWER, true)
	var mage := combat.players[MAGE]
	mage.strength = 2
	mage.next_attack_bonus = 3
	mage.poison = 2
	combat.enemy_block = 4
	_check(combat.play_card(MAGE, 5, TARGET) and combat.enemy_hp == 78 and combat.enemy_block == 0
		and mage.burning == 3, "Tower boosts Salvo's first hit alongside Strength and preparation before enemy Block")
	_check(combat.play_card(MAGE, 0, TARGET) and combat.enemy_hp == 70 and mage.burning == 3,
		"the second card does not repeat Tower")
	_check(combat.end_turn(MAGE) and combat.undo_ready(MAGE) and mage.hp == 36 and mage.burning == 3,
		"Ready/Undo does not tick Burning")
	_check(combat.end_turn(MAGE) and combat.end_turn(ALLY) and mage.hp == 31 and mage.burning == 2
		and mage.poison == 1 and mage.arcana_used, "Burning at closure and Poison at turn start each resolve once")
	var lethal := _combat(Arcana.TOWER)
	lethal.enemy_hp = 10
	_check(lethal.play_card(MAGE, 0, TARGET) and lethal.phase == Combat.Phase.VICTORY
		and lethal.players[MAGE].burning == 3 and lethal.players[MAGE].hp == 36,
		"the complete lethal card applies Burning and reaches victory without ticking it")


func _check(condition: bool, context: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(context)
