package sim

import "../ecs"

// Each queue is drained by exactly one procedure, and each drain clears the
// queue it owns. Anything appended *after* its drain - by a later system in
// the step, such as `consequences_system` in sys_consequences.odin - survives to
// be drained on the next fixed step rather than being silently dropped.
//
// Everything in this file consumes a queue. A pass that reads component arrays
// without draining anything belongs in a systems_*.odin file instead.
//
// They take a `dt` they do not use, because everything in `SCHEDULE` has the
// same shape - the same reason `facing_system` and `consequences_system` do.

// The only writer to the health array.
drain_damage :: proc(s: ^State, dt: f32) {
	for event in s.events.damage {
		health := ecs.get(&s.status.health, event.target)
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
			position = ecs.get_or(&s.spatial.position, event.target, Vec2{}),
		})
	}
	clear(&s.events.damage)
}

// What a hit costs. Runs before `drain_damage`, so a hit landed this tick is
// paid for in the same tick rather than the next one.
//
// The damage still goes through the damage queue rather than being written
// here: health has exactly one writer, and a fireball is not a reason to make
// it two. What this drain owns is the rest of the consequence - the end of the
// projectile, and whatever an impact grows to mean later.
drain_hits :: proc(s: ^State, dt: f32) {
	for event in s.events.hits {
		// Two targets can be reached in one tick by one projectile only if it
		// was already spent by an earlier event; a stale handle is the normal
		// way to find that out, not an error.
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
		// Two collectors can overlap the same item in one step; the first
		// one destroys it and the second finds a stale handle.
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
