extends RefCounted

const MAGICIAN := &"the_magician"
const STRENGTH := &"strength"
const JUSTICE := &"justice"
const TOWER := &"the_tower"
const BATTLE_MAGE := &"battle_mage"

const STRENGTH_ATTACKS := 3
const JUSTICE_THRESHOLD := 5
const JUSTICE_BLOCK := 4
const TOWER_DAMAGE := 5
const TOWER_BURNING := 3


static func offers(run_seed: int, seat: int, class_id: StringName) -> Array[StringName]:
	if class_id != BATTLE_MAGE:
		return []
	# Use a separate per-seat stream so offers never advance combat's shuffle RNG.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([run_seed, seat, "major_arcana"])
	var pool: Array[StringName] = [MAGICIAN, STRENGTH, JUSTICE, TOWER]
	var result: Array[StringName] = []
	for index in 3:
		var chosen := rng.randi_range(index, pool.size() - 1)
		var previous := pool[index]
		pool[index] = pool[chosen]
		pool[chosen] = previous
		result.append(pool[index])
	return result


static func view(id: StringName) -> Dictionary:
	var title: String
	var description: String
	match id:
		MAGICIAN:
			title = "The Magician"
			description = "Once per round, after you play both an Attack and a non-Attack, draw 1 card."
		STRENGTH:
			title = "Strength"
			description = "After your %drd Attack each combat resolves, gain 1 Strength." % STRENGTH_ATTACKS
		JUSTICE:
			title = "Justice"
			description = "Once per round, after an Attack you started with at least %d Block resolves, gain %d Block." % [JUSTICE_THRESHOLD, JUSTICE_BLOCK]
		TOWER:
			title = "The Tower"
			description = "Your first damaging Attack each combat deals +%d damage on its first hit. After it resolves, gain %d Burning." % [TOWER_DAMAGE, TOWER_BURNING]
		_:
			return {}
	return {"id": String(id), "name": title, "description": description}
