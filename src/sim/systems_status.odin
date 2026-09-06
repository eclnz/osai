package sim

import "../ecs"

// Consequences of condition: what happens to an entity because of the state
// it is in, rather than because of anything it did this step.
//
// Death is the only one today. It lives outside drains.odin because it drains
// nothing - it is a pass over the health array, not a queue consumer. Its
// placement in the step still matters though: `step.odin` runs it after every
// queue that could have changed health, so a lethal hit and the death it
// causes land in the same tick.
//
// Collecting into `dead` before acting is not an optimisation. Destroying
// inline would swap-and-pop the health array underneath the loop and skip the
// entity moved into the freed slot.
consequences_system :: proc(s: ^State, dt: f32) {
	dead := make([dynamic]ecs.Entity, context.temp_allocator)
	for health, i in s.status.health.dense {
		if health.current <= 0 {
			append(&dead, s.status.health.owners[i])
		}
	}

	for e in dead {
		append(&s.events.sounds, Sound_Request{
			sound    = .Death,
			position = ecs.get_or(&s.spatial.position, e, Vec2{}),
		})
		// No death animation to play out yet: the entity goes immediately.
		// Holding it for the animation would mean a `dying` component, which
		// is a decision for whenever combat becomes real.
		entity_destroy(s, e)
	}
}
