package sim

import "../ecs"

// Each queue is drained by exactly one procedure, which clears it. Anything
// appended after its own drain survives to the next fixed step rather than
// being dropped.
//
// The unused `dt` is there because every row in `SCHEDULE` has one shape.

// The only writer to the health array.
drain_damage :: proc(s: ^State, dt: f32) {
	for event in s.events.damage {
		health := ecs.get(&s.status.health, event.target)
		if health == nil {
			// No health component: not damageable. Not an error.
			continue
		}

		health.current = max(0, health.current - event.amount)

		// Writes a command and moves on; the animation system decides whether
		// it outranks what it would derive.
		command_animation(s, event.target, .Hurt, 200, 0.30)

		append(&s.events.sounds, Sound_Request{
			sound    = .Hurt,
			position = ecs.get_or(&s.spatial.position, event.target, Vec2{}),
		})
	}
	clear(&s.events.damage)
}

// Runs before `drain_damage`, so a hit landed this tick is paid for in it.
// The damage still goes through the queue: health has exactly one writer.
drain_hits :: proc(s: ^State, dt: f32) {
	for event in s.events.hits {
		// A projectile already spent by an earlier event this tick shows up as
		// a stale handle. Normal, not an error.
		if !ecs.entity_is_alive(&s.entities, event.projectile) {
			continue
		}
		append(&s.events.damage, Damage_Event{
			target = event.target,
			amount = event.damage,
			source = .Projectile,
		})
		entity_destroy(s, event.projectile)
	}
	clear(&s.events.hits)
}

drain_pickups :: proc(s: ^State, dt: f32) {
	for event in s.events.pickups {
		// Two collectors can overlap one item in a step. The first destroys
		// it, and that is what makes the second's handle stale.
		if !ecs.entity_is_alive(&s.entities, event.item_entity) {
			continue
		}
		inv := ecs.get(&s.items.inventory, event.collector)
		if inv == nil {
			continue
		}

		added := inventory_add(inv, event.item, event.count)
		if added == 0 {
			continue // inventory full; the item stays in the world
		}
		if added < event.count {
			if slot := ecs.get(&s.items.item, event.item_entity); slot != nil {
				slot.count -= added
				continue
			}
		}

		append(&s.events.sounds, Sound_Request{
			sound    = .Pickup,
			position = ecs.get_or(&s.spatial.position, event.item_entity, Vec2{}),
		})
		entity_destroy(s, event.item_entity)
	}
	clear(&s.events.pickups)
}

drain_spawns :: proc(s: ^State, dt: f32) {
	// Spawning appends nothing here today; the length copy keeps that from
	// being load-bearing.
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
