extends RefCounted

const CardData = preload("res://scripts/combat/card_data.gd")
const CardEffect = preload("res://scripts/combat/card_effect.gd")
const EncounterData = preload("res://scripts/combat/encounter_data.gd")
const EnemyAction = preload("res://scripts/combat/enemy_action.gd")
const EnemyData = preload("res://scripts/combat/enemy_data.gd")
const EnemyState = preload("res://scripts/combat/enemy_state.gd")
const MajorArcana = preload("res://scripts/run/major_arcana.gd")
const RuneMatcher = preload("res://scripts/combat/rune_matcher.gd")
const SpellDrawingSettings = preload("res://scripts/combat/spell_drawing_settings.gd")

enum Phase { PLAYER, ENEMY, VICTORY, DEFEAT }
enum CastResult { NO_CAST, SUCCESS, MISDRAWN, EXPIRED, INVALID }

const TURN_MANA := 3
const TURN_DRAW := 5


class PlayerState:
	var id: StringName
	var hp: int
	var max_hp: int
	var mana: int
	var block: int
	var strength: int
	var dexterity: int
	var poison: int
	var burning: int
	var next_attack_bonus: int
	# Ready is reversible until the shared phase closes.
	var ended_turn: bool
	var ready_epoch: int
	var arcana_id: StringName
	var arcana_used: bool
	var arcana_attacks: int
	var arcana_saw_attack: bool
	var arcana_saw_non_attack: bool
	var recovered_after_victory: bool
	var spell_booster_primed := false
	var first_copy_id: int
	var hand: Array[int] = []
	var draw_pile: Array[int] = []
	var discard_pile: Array[int] = []


class PendingCast:
	var copy_id: int
	var target_id: StringName
	var deadline_ms := -1
	var guide: Array[PackedVector2Array]
	var boosted: bool


var phase: Phase = Phase.PLAYER
var round_number: int
var shuffle_seed: int
var enemies: Array[EnemyState] = []
# Legacy single-enemy callers read or set the first enemy through these properties.
var enemy_hp: int:
	get: return enemies[0].hp
	set(value): enemies[0].hp = value
var enemy_block: int:
	get: return enemies[0].block
	set(value): enemies[0].block = value
var enemy_strength: int:
	get: return enemies[0].strength
	set(value): enemies[0].strength = value
var enemy_dexterity: int:
	get: return enemies[0].dexterity
	set(value): enemies[0].dexterity = value
var enemy_poison: int:
	get: return enemies[0].poison
	set(value): enemies[0].poison = value
var enemy_burning: int:
	get: return enemies[0].burning
	set(value): enemies[0].burning = value
var players: Dictionary[StringName, PlayerState] = {}
var action_history: Array[Dictionary] = []
var combat_log: PackedStringArray = []

var _enemies_by_id: Dictionary[StringName, EnemyState] = {}
var _cards: Array[CardData] = []
var _rng := RandomNumberGenerator.new()
var _spell_drawing: SpellDrawingSettings
var _bypass_drawing := false
var _parallel_casts := false
var _pending_casts: Dictionary[StringName, PendingCast] = {}


func _init(encounter: EncounterData, encounter_seed: int, player_ids: Array[StringName], starting_hp := -1,
		player_decks: Dictionary[StringName, Array] = {}, player_hps: Dictionary[StringName, int] = {},
		arcana_by_player: Dictionary[StringName, StringName] = {}, spell_drawing: SpellDrawingSettings = null,
		bypass_drawing := false, parallel_casts := false) -> void:
	assert(not player_ids.is_empty(), "Combat requires at least one player.")
	_spell_drawing = spell_drawing
	_bypass_drawing = bypass_drawing
	_parallel_casts = parallel_casts
	shuffle_seed = encounter_seed
	_rng.seed = shuffle_seed
	var definitions := encounter.enemies
	if definitions.is_empty():
		definitions = [encounter.legacy_enemy_data()]
	for definition: EnemyData in definitions:
		assert(definition != null and definition.id != &"" and not _enemies_by_id.has(definition.id),
			"Combat enemy IDs must be nonempty and unique.")
		var enemy := EnemyState.new(definition)
		enemies.append(enemy)
		_enemies_by_id[enemy.id] = enemy
	_log("Encounter started. Seed %d." % shuffle_seed)
	for player_id in player_ids:
		assert(not players.has(player_id), "Combat player IDs must be unique.")
		var player := PlayerState.new()
		player.id = player_id
		player.arcana_id = arcana_by_player.get(player_id, &"")
		player.max_hp = encounter.player_max_hp
		player.hp = player_hps.get(player_id, player.max_hp if starting_hp < 0 else starting_hp)
		player.first_copy_id = _cards.size()
		for card in player_decks.get(player_id, encounter.test_deck):
			player.draw_pile.append(_cards.size())
			_cards.append(card)
		_shuffle(player.draw_pile)
		players[player_id] = player
	_begin_player_phase()


func card_data(copy_id: int) -> CardData:
	return _cards[copy_id]


func arcana_view(player_id: StringName) -> Dictionary:
	var player := players[player_id]
	var view := MajorArcana.view(player.arcana_id)
	match player.arcana_id:
		MajorArcana.MAGICIAN:
			if player.arcana_used:
				view["progress"] = "Used this round"
			elif player.arcana_saw_attack:
				view["progress"] = "Needs a non-Attack"
			elif player.arcana_saw_non_attack:
				view["progress"] = "Needs an Attack"
			else:
				view["progress"] = "Needs an Attack and a non-Attack"
		MajorArcana.STRENGTH:
			view["progress"] = "%d/%d Attacks this combat" % [player.arcana_attacks, MajorArcana.STRENGTH_ATTACKS]
		MajorArcana.JUSTICE:
			view["progress"] = "Used this round" if player.arcana_used else "Available this round"
		MajorArcana.TOWER:
			view["progress"] = "Used this combat" if player.arcana_used else "Available this combat"
	return view


func enemy_state(target_id: StringName) -> EnemyState:
	return _enemies_by_id.get(target_id)


func enemy_intent() -> Dictionary:
	return enemies[0].intent_at(round_number - 1)


func enemy_attack_damage() -> int:
	var intent := enemy_intent()
	return intent.amount if intent.kind == EnemyAction.Kind.ATTACK else 0


func can_play_card(player_id: StringName, copy_id: int, target_id: StringName) -> bool:
	return not _casting_blocks_actions(player_id) and _card_is_legal(player_id, copy_id, target_id)


func _casting_blocks_actions(player_id: StringName) -> bool:
	return _pending_casts.has(player_id) if _parallel_casts else not _pending_casts.is_empty()


func _card_is_legal(player_id: StringName, copy_id: int, target_id: StringName) -> bool:
	var player: PlayerState = players.get(player_id)
	if not _can_act(player) or not player.hand.has(copy_id):
		return false
	var card := card_data(copy_id)
	if player.mana < card.mana_cost:
		return false
	if card.is_spell_booster and (_spell_drawing == null or player.spell_booster_primed):
		return false
	if not card.targets_enemy():
		return target_id == &""
	var target := enemy_state(target_id)
	return target != null and target.is_alive()


func play_card(player_id: StringName, copy_id: int, target_id: StringName) -> bool:
	if not can_play_card(player_id, copy_id, target_id) or requires_rune(copy_id):
		return false
	var player := players[player_id]
	var card := card_data(copy_id)
	if _spell_drawing != null and card.rune_template != null and not card.is_spell_booster:
		var boosted := player.spell_booster_primed and card.rune_template.booster_stroke.size() >= 2
		var power := 100 + (_spell_drawing.booster_bonus_percent if boosted else 0)
		if boosted:
			player.spell_booster_primed = false
		_resolve_card(player, copy_id, target_id, power)
	else:
		_resolve_card(player, copy_id, target_id)
	return true


func requires_rune(copy_id: int) -> bool:
	return (_spell_drawing != null and not _bypass_drawing and copy_id >= 0 and copy_id < _cards.size()
		and card_data(copy_id).rune_template != null and not card_data(copy_id).is_spell_booster)


func begin_spell_cast(player_id: StringName, copy_id: int, target_id: StringName) -> Dictionary:
	if not can_play_card(player_id, copy_id, target_id) or not requires_rune(copy_id):
		return {}
	var card := card_data(copy_id)
	var template := card.rune_template
	var cast := PendingCast.new()
	cast.copy_id = copy_id
	cast.target_id = target_id
	cast.guide = template.strokes.duplicate()
	cast.boosted = players[player_id].spell_booster_primed and template.booster_stroke.size() >= 2
	if cast.boosted:
		cast.guide.append(template.booster_stroke)
	_pending_casts[player_id] = cast
	var display_guide: Array[PackedVector2Array] = []
	for stroke in cast.guide:
		display_guide.append(stroke.duplicate())
	return {"card_name": card.display_name, "rune_name": template.display_name,
		"guide": display_guide, "boosted": cast.boosted}


func start_spell_cast_clock(player_id: StringName, now_ms: int) -> int:
	var cast: PendingCast = _pending_casts.get(player_id)
	if cast == null or cast.deadline_ms >= 0:
		return -1
	var template := card_data(cast.copy_id).rune_template
	cast.deadline_ms = now_ms + template.cast_time_ms
	return cast.deadline_ms


func is_spell_cast_valid(player_id: StringName) -> bool:
	var cast: PendingCast = _pending_casts.get(player_id)
	return cast != null and _card_is_legal(player_id, cast.copy_id, cast.target_id)


func submit_spell_cast(player_id: StringName, strokes: Array[PackedVector2Array], now_ms: int) -> CastResult:
	var cast: PendingCast = _pending_casts.get(player_id)
	if cast == null or cast.deadline_ms < 0:
		return CastResult.NO_CAST
	_pending_casts.erase(player_id)
	if not _card_is_legal(player_id, cast.copy_id, cast.target_id):
		return CastResult.INVALID
	var boosted := cast.boosted and strokes.size() == cast.guide.size()
	var base_guide := card_data(cast.copy_id).rune_template.strokes
	var recognized := _match_spell_rune(cast.guide if boosted else base_guide, strokes)
	if boosted and recognized == null:
		# A failed added stroke can leave enough ink for the ordinary spell.
		recognized = _match_spell_rune(base_guide, strokes, true)
		boosted = false
	if recognized == null:
		return CastResult.EXPIRED if now_ms >= cast.deadline_ms else CastResult.MISDRAWN
	var quality := _spell_drawing.quality(recognized.score, recognized.complete and (not cast.boosted or boosted))
	var player := players[player_id]
	if cast.boosted:
		player.spell_booster_primed = false
	_resolve_card(player, cast.copy_id, cast.target_id, _spell_drawing.power_percent(quality, boosted), quality)
	return CastResult.SUCCESS


func _match_spell_rune(guide: Array[PackedVector2Array], strokes: Array[PackedVector2Array],
		allow_failed_augmentation := false) -> RuneMatcher.MatchResult:
	return RuneMatcher.recognize(guide, strokes, _spell_drawing.minimum_extent,
		_spell_drawing.recognition_tolerance, _spell_drawing.minimum_coverage, allow_failed_augmentation)


func expire_spell_cast(player_id: StringName, strokes: Array[PackedVector2Array], now_ms: int) -> CastResult:
	var cast: PendingCast = _pending_casts.get(player_id)
	if cast == null or cast.deadline_ms < 0 or now_ms < cast.deadline_ms:
		return CastResult.NO_CAST
	return submit_spell_cast(player_id, strokes, now_ms)


func cancel_spell_cast(player_id: StringName) -> bool:
	return _pending_casts.erase(player_id)


func _resolve_card(player: PlayerState, copy_id: int, target_id: StringName, power_percent := 100,
		cast_quality := "") -> void:
	var card := card_data(copy_id)
	var target := enemy_state(target_id)
	var justice_qualifies := (player.arcana_id == MajorArcana.JUSTICE and not player.arcana_used
		and card.is_attack and player.block >= MajorArcana.JUSTICE_THRESHOLD)
	var tower_available := player.arcana_id == MajorArcana.TOWER and not player.arcana_used and card.is_attack
	var tower_triggered := false
	var action := {&"command": &"play_card", &"player": player.id, &"copy": copy_id, &"target": target_id}
	if _spell_drawing != null and card.rune_template != null:
		action[&"spell_power_percent"] = power_percent
		_log("%s cast %s at %d%% base power." % [player.id, card.rune_template.display_name, power_percent])
	if not cast_quality.is_empty():
		action[&"spell_quality"] = cast_quality
	action_history.append(action)
	player.mana -= card.mana_cost
	player.hand.erase(copy_id)
	_log("%s played %s for %d Mana." % [player.id, card.display_name, card.mana_cost])
	if card.is_spell_booster:
		player.spell_booster_primed = true
		_log("%s primed a rune enhancement for their next drawn spell." % player.id)
	for effect in card.effects:
		match effect.kind:
			CardEffect.Kind.DAMAGE:
				var tower_bonus := MajorArcana.TOWER_DAMAGE if tower_available and not tower_triggered else 0
				tower_triggered = tower_triggered or tower_bonus > 0
				_deal_card_damage(player, target, card, effect, tower_bonus, power_percent)
			CardEffect.Kind.GAIN_BLOCK:
				var block_gain := _spell_base_amount(effect.amount, power_percent)
				if effect.amount > 0:
					block_gain += player.dexterity
				player.block += block_gain
				_log("%s gained %d Block." % [player.id, block_gain])
			CardEffect.Kind.DRAW:
				_draw(player, effect.amount)
			CardEffect.Kind.PREPARE_ATTACK:
				# TODO(design): Multiple preparations add to the same next Attack in this playtest.
				player.next_attack_bonus += effect.amount
				_log("%s prepared their next Attack for +%d damage this turn." % [
					player.id, player.next_attack_bonus])
			CardEffect.Kind.APPLY_POISON, CardEffect.Kind.APPLY_BURNING:
				_apply_card_status(target, effect)
			CardEffect.Kind.GAIN_STRENGTH:
				if effect.amount > 0:
					player.strength += effect.amount
					_log("%s gained %d Strength." % [player.id, effect.amount])
			CardEffect.Kind.GAIN_DEXTERITY:
				if effect.amount > 0:
					player.dexterity += effect.amount
					_log("%s gained %d Dexterity." % [player.id, effect.amount])
	_resolve_arcana_after_card(player, card, justice_qualifies, tower_triggered)
	player.discard_pile.append(copy_id)
	_finish_if_enemies_down()


func can_end_turn(player_id: StringName) -> bool:
	return not _casting_blocks_actions(player_id) and _can_act(players.get(player_id))


func end_turn(player_id: StringName) -> bool:
	var player: PlayerState = players.get(player_id)
	if not can_end_turn(player_id):
		return false
	action_history.append({&"command": &"end_turn", &"player": player_id})
	player.ended_turn = true
	player.ready_epoch += 1
	if _has_unready_living_players():
		_log("%s is ready." % player.id)
	else:
		_close_player_phase()
	return true


func can_undo_ready(player_id: StringName) -> bool:
	var player: PlayerState = players.get(player_id)
	return (not _casting_blocks_actions(player_id) and phase == Phase.PLAYER and player != null and player.hp > 0 and player.ended_turn
		and _has_unready_living_players())


func undo_ready(player_id: StringName) -> bool:
	if not can_undo_ready(player_id):
		return false
	var player := players[player_id]
	action_history.append({&"command": &"undo_ready", &"player": player_id})
	player.ended_turn = false
	player.ready_epoch += 1
	_log("%s undid ready." % player.id)
	return true


func _has_unready_living_players() -> bool:
	for player: PlayerState in players.values():
		if player.hp > 0 and not player.ended_turn:
			return true
	return false


func _close_player_phase() -> void:
	# Lock player input before resolving any end-of-turn effects.
	phase = Phase.ENEMY
	for player: PlayerState in players.values():
		if player.hp > 0:
			_finalize_player_turn(player)
	if not _finish_if_party_down():
		_resolve_enemy_phase()


func _finalize_player_turn(player: PlayerState) -> void:
	player.mana = 0
	if player.next_attack_bonus > 0:
		_log("%s's next Attack bonus expired at turn end." % player.id)
		player.next_attack_bonus = 0
	if not player.hand.is_empty():
		_log("%s discarded %d unplayed cards." % [player.id, player.hand.size()])
		player.discard_pile.append_array(player.hand)
		player.hand.clear()
	_log("%s ended their turn." % player.id)
	if player.burning > 0:
		player.hp = _take_status_damage(player.hp, player.burning, "Burning", player.id)
		player.burning = _remaining_burning(player.burning)
		if player.hp == 0:
			_log("%s was defeated." % player.id)


func _resolve_arcana_after_card(player: PlayerState, card: CardData, justice_qualifies: bool, tower_triggered: bool) -> void:
	match player.arcana_id:
		MajorArcana.MAGICIAN:
			if not player.arcana_used:
				player.arcana_saw_attack = player.arcana_saw_attack or card.is_attack
				player.arcana_saw_non_attack = player.arcana_saw_non_attack or not card.is_attack
				if player.arcana_saw_attack and player.arcana_saw_non_attack:
					player.arcana_used = true
					_draw(player, 1)
		MajorArcana.STRENGTH:
			if card.is_attack and player.arcana_attacks < MajorArcana.STRENGTH_ATTACKS:
				player.arcana_attacks += 1
				if player.arcana_attacks == MajorArcana.STRENGTH_ATTACKS:
					player.strength += 1
					_log("%s gained 1 Strength." % player.id)
		MajorArcana.JUSTICE:
			if justice_qualifies:
				player.arcana_used = true
				player.block += MajorArcana.JUSTICE_BLOCK
				_log("%s gained %d Block." % [player.id, MajorArcana.JUSTICE_BLOCK])
		MajorArcana.TOWER:
			if tower_triggered:
				player.arcana_used = true
				player.burning += MajorArcana.TOWER_BURNING
				_log_status_application(player.id, MajorArcana.TOWER_BURNING, "Burning")


func _deal_card_damage(player: PlayerState, enemy: EnemyState, card: CardData, effect: CardEffect,
		arcana_bonus: int, power_percent: int) -> void:
	var damage := _spell_base_amount(effect.amount, power_percent)
	if effect.block_per_bonus > 0:
		@warning_ignore("integer_division")
		var block_bonus := player.block / effect.block_per_bonus
		damage += block_bonus
		_log("%s added %d damage from %d Block." % [card.display_name, block_bonus, player.block])
	if effect.block_to_spend > 0:
		if player.block >= effect.block_to_spend:
			player.block -= effect.block_to_spend
			damage += effect.damage_on_block_spend
			_log("%s spent %d Block for +%d damage." % [
				card.display_name, effect.block_to_spend, effect.damage_on_block_spend])
		else:
			_log("%s needs %d Block for bonus damage. %s has %d Block and spent none." % [
				card.display_name, effect.block_to_spend, player.id, player.block])
	if card.is_attack and player.strength > 0:
		damage += player.strength
		_log("%s added %d Attack damage from Strength." % [player.id, player.strength])
	# TODO(design): Apply preparation once, to the first hit of the owner's next Attack.
	if card.is_attack and player.next_attack_bonus > 0:
		damage += player.next_attack_bonus
		_log("%s used their preparation for +%d Attack damage." % [player.id, player.next_attack_bonus])
		player.next_attack_bonus = 0
	damage += arcana_bonus
	var enemy_label := _enemy_label(enemy)
	var absorbed := mini(enemy.block, maxi(0, damage))
	if absorbed > 0:
		enemy.block -= absorbed
		_log("%s blocked %d damage." % [enemy_label, absorbed])
	var hp_lost := mini(enemy.hp, damage - absorbed)
	enemy.hp -= hp_lost
	_log("%s took %d damage." % [enemy_label, hp_lost])
	if hp_lost > 0 and not enemy.is_alive():
		_log_enemy_defeat(enemy_label)


func _spell_base_amount(amount: int, power_percent: int) -> int:
	return amount if power_percent == 100 else roundi(amount * (power_percent / 100.0))


func _apply_card_status(enemy: EnemyState, effect: CardEffect) -> void:
	if not enemy.is_alive() or effect.amount <= 0:
		return
	if effect.kind == CardEffect.Kind.APPLY_POISON:
		enemy.poison += effect.amount
		_log_status_application(_enemy_label(enemy), effect.amount, "Poison")
	else:
		# Provisional: repeated Burning applications add their stacks.
		enemy.burning += effect.amount
		_log_status_application(_enemy_label(enemy), effect.amount, "Burning")


func _take_status_damage(hp: int, stacks: int, status_name: String, target: String) -> int:
	var hp_lost := mini(hp, stacks)
	_log("%s lost %d HP to %s." % [target, hp_lost, status_name])
	return hp - hp_lost


func _remaining_burning(stacks: int) -> int:
	@warning_ignore("integer_division")
	return stacks - stacks / 2


func _can_act(player: PlayerState) -> bool:
	return phase == Phase.PLAYER and player != null and player.hp > 0 and not player.ended_turn


func _begin_player_phase() -> void:
	phase = Phase.PLAYER
	round_number += 1
	_log("Turn %d. Player phase." % round_number)
	for player: PlayerState in players.values():
		if player.hp <= 0:
			continue
		if player.block > 0:
			_log("%s lost %d remaining Block at turn start." % [player.id, player.block])
		player.block = 0
		if player.poison > 0:
			player.hp = _take_status_damage(player.hp, player.poison, "Poison", player.id)
			player.poison -= 1
			if player.hp == 0:
				_log("%s was defeated." % player.id)
				continue
		player.mana = TURN_MANA
		player.ended_turn = false
		if player.arcana_id in [MajorArcana.MAGICIAN, MajorArcana.JUSTICE]:
			player.arcana_used = false
			player.arcana_saw_attack = false
			player.arcana_saw_non_attack = false
		_draw(player, TURN_DRAW)
	_finish_if_party_down()


func _resolve_enemy_phase() -> void:
	# Provisional: finish each enemy's action and status boundaries before the next slot.
	for enemy in enemies:
		if not enemy.is_alive():
			continue
		_resolve_enemy_turn(enemy)
		if phase == Phase.DEFEAT:
			return
	if not _finish_if_enemies_down():
		_begin_player_phase()


func _resolve_enemy_turn(enemy: EnemyState) -> void:
	var enemy_label := _enemy_label(enemy)
	if enemy.block > 0:
		_log("%s lost %d remaining Block at action start." % [enemy_label, enemy.block])
		enemy.block = 0
	if enemy.poison > 0:
		enemy.hp = _take_status_damage(enemy.hp, enemy.poison, "Poison", enemy_label)
		enemy.poison -= 1
		if not enemy.is_alive():
			_log_enemy_defeat(enemy_label)
			return
	var intent := enemy.intent()
	var amount: int = intent.amount
	enemy.action_index += 1
	match intent.kind:
		EnemyAction.Kind.ATTACK:
			_resolve_enemy_attack(enemy, enemy_label, amount)
			# Provisional: a party wipe stops before Burning and the remaining enemies' turns.
			if _finish_if_party_down():
				return
		EnemyAction.Kind.BLOCK:
			enemy.block += amount
			_log("%s gained %d Block." % [enemy_label, amount])
		EnemyAction.Kind.GAIN_STRENGTH:
			enemy.strength += amount
			_log("%s gained %d Strength." % [enemy_label, amount])
	if enemy.burning > 0:
		enemy.hp = _take_status_damage(enemy.hp, enemy.burning, "Burning", enemy_label)
		enemy.burning = _remaining_burning(enemy.burning)
		if not enemy.is_alive():
			_log_enemy_defeat(enemy_label)


func _resolve_enemy_attack(enemy: EnemyState, enemy_label: String, attack_damage: int) -> void:
	_log("%s attacks for %d damage." % [enemy_label, attack_damage])
	for player: PlayerState in players.values():
		if player.hp <= 0:
			continue
		var absorbed := mini(player.block, attack_damage)
		var hp_lost := mini(player.hp, attack_damage - absorbed)
		player.block -= absorbed
		player.hp -= hp_lost
		_log("%s blocked %d and lost %d HP." % [player.id, absorbed, hp_lost])
		if player.hp == 0:
			_log("%s was defeated." % player.id)
			continue
		_apply_attack_statuses(enemy, player)


func _apply_attack_statuses(enemy: EnemyState, player: PlayerState) -> void:
	if enemy.poison_per_attack > 0:
		player.poison += enemy.poison_per_attack
		_log_status_application(player.id, enemy.poison_per_attack, "Poison")
	if enemy.burning_per_attack > 0:
		player.burning += enemy.burning_per_attack
		_log_status_application(player.id, enemy.burning_per_attack, "Burning")


func _enemy_label(enemy: EnemyState) -> String:
	var same_name_count := 0
	var name_number := 0
	for other in enemies:
		if other.display_name == enemy.display_name:
			same_name_count += 1
			if other == enemy:
				name_number = same_name_count
	return "%s (%d)" % [enemy.display_name, name_number] if same_name_count > 1 else enemy.display_name


func _log_enemy_defeat(enemy_label: String) -> void:
	if enemies.size() > 1:
		_log("%s was defeated." % enemy_label)


func _log_status_application(target: String, amount: int, status_name: String) -> void:
	_log("%s gained %d %s stacks." % [target, amount, status_name])


func _finish_if_party_down() -> bool:
	for player: PlayerState in players.values():
		if player.hp > 0:
			return false
	phase = Phase.DEFEAT
	_log("Defeat.")
	return true


func _finish_if_enemies_down() -> bool:
	for enemy in enemies:
		if enemy.is_alive():
			return false
	phase = Phase.VICTORY
	if enemies.size() == 1:
		_log("Victory. %s was defeated." % enemies[0].display_name)
	else:
		_log("Victory. All enemies were defeated.")
	for player: PlayerState in players.values():
		if player.hp == 0:
			@warning_ignore("integer_division")
			player.hp = player.max_hp / 4 + int(player.max_hp % 4 != 0)
			player.recovered_after_victory = true
			_log("%s recovered to %d/%d HP after victory." % [player.id, player.hp, player.max_hp])
	return true


func _draw(player: PlayerState, count: int) -> void:
	var drawn := 0
	while drawn < count:
		if player.draw_pile.is_empty():
			if player.discard_pile.is_empty():
				break
			player.draw_pile.assign(player.discard_pile)
			player.discard_pile.clear()
			_shuffle(player.draw_pile)
			_log("%s shuffled their discard pile into the draw pile." % player.id)
		player.hand.append(player.draw_pile.pop_back())
		drawn += 1
	_log("%s drew %d %s." % [player.id, drawn, "card" if drawn == 1 else "cards"])


func _shuffle(pile: Array[int]) -> void:
	for index in range(pile.size() - 1, 0, -1):
		var other_index := _rng.randi_range(0, index)
		var card := pile[index]
		pile[index] = pile[other_index]
		pile[other_index] = card


func _log(message: String) -> void:
	combat_log.append(message)
