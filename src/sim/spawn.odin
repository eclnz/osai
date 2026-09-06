package sim

import "../ecs"

@(private = "file")
spawn_base :: proc(s: ^State, kind: Entity_Kind, position: Vec2) -> ecs.Entity {
	def := entity_definitions[kind]
	e := ecs.entity_create(&s.entities)

	ecs.add(&s.identity.kind, e, kind)
	ecs.add(&s.spatial.position, e, position)
	ecs.add(&s.spatial.previous_position, e, position)
	ecs.add(&s.spatial.collider, e, Collider{size = def.collider})
	ecs.add(&s.presentation.appearance, e, Appearance{texture = def.texture, tint = def.tint})
	ecs.add(&s.presentation.layer, e, Layer{depth = def.depth})
	return e
}

spawn :: proc(s: ^State, req: Spawn_Request) -> ecs.Entity {
	switch req.kind {
	case .Player:
		return spawn_player(s, req.position)
	case .Walker:
		return spawn_walker(s, req.position)
	case .Coin:
		return spawn_coin(s, req.position)
	case .Rock:
		return spawn_rock(s, req.position)
	case .Fireball:
		// A request carries only a position, so one from generation or a save
		// gets a fireball that simply drops. Shooting one goes through
		// `spawn_fireball`, where the velocity is the point.
		return spawn_fireball(s, req.position, {}, ecs.NIL)
	}
	return ecs.NIL
}

spawn_player :: proc(s: ^State, position: Vec2) -> ecs.Entity {
	e := spawn_base(s, .Player, position)
	ecs.add(&s.spatial.velocity, e, Vec2{0, 0})
	ecs.add(&s.spatial.grounded, e, Grounded{})
	ecs.add(&s.spatial.facing, e, Facing(1))
	ecs.add(&s.control.intent, e, Intent{})
	ecs.add(&s.control.movement, e, Movement{def = .Player})
	ecs.add(&s.status.health, e, Health{current = entity_definitions[.Player].max_health})
	ecs.add(&s.presentation.animation, e, Animation_State{})
	ecs.add(&s.items.inventory, e, Inventory{})
	ecs.add(&s.combat.weapon, e, Weapon{})
	ecs.add(&s.control.digger, e, Digger{reach = 3 * TILE_SIZE, speed = 1})
	s.player = e
	return e
}

spawn_walker :: proc(s: ^State, position: Vec2) -> ecs.Entity {
	e := spawn_base(s, .Walker, position)
	ecs.add(&s.spatial.velocity, e, Vec2{0, 0})
	ecs.add(&s.spatial.grounded, e, Grounded{})
	ecs.add(&s.spatial.facing, e, Facing(1))
	ecs.add(&s.control.intent, e, Intent{})
	ecs.add(&s.control.movement, e, Movement{def = .Walker})
	ecs.add(&s.control.ai, e, AI_State{behaviour = .Patrol, facing = 1})
	ecs.add(&s.status.health, e, Health{current = entity_definitions[.Walker].max_health})
	ecs.add(&s.presentation.animation, e, Animation_State{})
	return e
}

// An item slot on top of the base. No health, so nothing can damage it; no
// velocity, so nothing moves it. Declared by the lines that are not written.
spawn_coin :: proc(s: ^State, position: Vec2) -> ecs.Entity {
	e := spawn_base(s, .Coin, position)
	ecs.add(&s.items.item, e, Item_Slot{item = .Coin, count = 1})
	return e
}

// Identical to a coin but for its row and its item, which is the point:
// nothing in mining or pickup says anything about rocks.
spawn_rock :: proc(s: ^State, position: Vec2) -> ecs.Entity {
	e := spawn_base(s, .Rock, position)
	ecs.add(&s.items.item, e, Item_Slot{item = .Rock, count = 1})
	return e
}

// A velocity so it moves, a projectile so it expires and deals damage, a
// bounce so terrain reflects it. No `intent`, `movement` or `grounded`: it is
// not steered, does not walk, and never stands on anything.
spawn_fireball :: proc(s: ^State, position: Vec2, velocity: Vec2, owner: ecs.Entity) -> ecs.Entity {
	e := spawn_base(s, .Fireball, position)
	ecs.add(&s.spatial.velocity, e, velocity)
	ecs.add(&s.spatial.bounce, e, Bounce{
		restitution = 0.6,
		friction    = 0.15,
		rolling     = 240,
		min_speed   = 30,
	})
	ecs.add(&s.combat.projectile, e, Projectile{
		owner  = owner,
		damage = FIREBALL_DAMAGE,
		life   = FIREBALL_LIFETIME,
	})
	return e
}
