package sim

import "../ecs"

// Each queue is drained by exactly one procedure, and each drain clears the
// queue it owns. Anything appended *after* its drain (by the consequences
// system, say) survives to be drained on the next fixed step rather than
// being silently dropped.

// The only writer to the health array.
drain_damage :: proc(s: ^State) {
	for event in s.events.damage {
		health := ecs.get(&s.health, event.target)
		if health == nil {
			// No health component: not damageable. Not an error, not a
			// special case - just an entity that is not in the array.
			continue
		}

		health.current = max(0, health.current - event.amount)

		// The damage system does not know how to animate anything. It writes
		// a command into the animation state and moves on; the animation
		// system decides whether that command wins.
		command_animation(s, event.target, .Hurt, 200, 0.30)

		append(&s.events.sounds, Sound_Request{
			sound    = .Hurt,
			position = ecs.get_or(&s.position, event.target, Vec2{}),
		})
	}
	clear(&s.events.damage)
}

drain_pickups :: proc(s: ^State) {
	for event in s.events.pickups {
		// Two collectors can overlap the same item in one step; the first
		// one destroys it and the second finds a stale handle.
		if !ecs.is_alive(&s.entities, event.item_entity) {
			continue
		}
		inv := ecs.get(&s.inventory, event.collector)
		if inv == nil {
			continue
		}

		added := inventory_add(inv, event.item, event.count)
		if added == 0 {
			continue // inventory full; the item stays in the world
		}
		if added < event.count {
			if slot := ecs.get(&s.item, event.item_entity); slot != nil {
				slot.count -= added
				continue
			}
		}

		append(&s.events.sounds, Sound_Request{
			sound    = .Pickup,
			position = ecs.get_or(&s.position, event.item_entity, Vec2{}),
		})
		destroy_entity(s, event.item_entity)
	}
	clear(&s.events.pickups)
}

drain_spawns :: proc(s: ^State) {
	// Spawning appends nothing to this queue, but taking a copy of the length
	// first keeps that from being load-bearing.
	count := len(s.events.spawns)
	for i in 0 ..< count {
		spawn(s, s.events.spawns[i])
	}
	if count == len(s.events.spawns) {
		clear(&s.events.spawns)
	} else {
		copy(s.events.spawns[:], s.events.spawns[count:])
		resize(&s.events.spawns, len(s.events.spawns) - count)
	}
}

// Consequences - death checks and state changes, after every queue that could
// have changed health has been drained.
consequences_system :: proc(s: ^State, dt: f32) {
	dead := make([dynamic]ecs.Entity, context.temp_allocator)
	for health, i in s.health.dense {
		if health.current <= 0 {
			append(&dead, s.health.owners[i])
		}
	}

	for e in dead {
		append(&s.events.sounds, Sound_Request{
			sound    = .Death,
			position = ecs.get_or(&s.position, e, Vec2{}),
		})
		// No death animation to play out yet: the entity goes immediately.
		// Holding it for the animation would mean a `dying` component, which
		// is a decision for whenever combat becomes real.
		destroy_entity(s, e)
	}
}
