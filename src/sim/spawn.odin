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

// A coin adds only an item slot on top of the base. It has no health, so
// nothing can damage it; no velocity or grounded, so nothing moves it. Those
// are still declared by absence - the lines are simply not written.
spawn_coin :: proc(s: ^State, position: Vec2) -> ecs.Entity {
	e := spawn_base(s, .Coin, position)
	ecs.add(&s.items.item, e, Item_Slot{item = .Coin, count = 1})
	return e
}
