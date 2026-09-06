package sim

import "../ecs"

// What happens to an entity because of the state it is in, rather than
// anything it did. Death is the only one today.
//
// Not a drain - it consumes no queue - but `SCHEDULE` runs it after every
// queue that could have changed health, so a lethal hit and the death it
// causes land in the same tick.
//
// Marking before acting is not an optimisation: destroying inline would
// swap-and-pop the array underneath the loop. See `pending_destroy`.
consequences_system :: proc(s: ^State, dt: f32) {
	for health, i in s.status.health.dense {
		if health.current <= 0 {
			destroy_pending(s, s.status.health.owners[i])
		}
	}

	for e in s.pending_destroy {
		append(&s.events.sounds, Sound_Request{
			sound    = .Death,
			position = ecs.get_or(&s.spatial.position, e, Vec2{}),
		})
	}
	// No death animation yet: holding the entity for one would mean a `dying`
	// component, and that decision is not due.
	flush_pending_destroys(s)
}
