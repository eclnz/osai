package sim

import "../ecs"
import "core:math"

// Firing and flight. Terrain contact is not here: a fireball bounces because
// it carries a `Bounce`, which `terrain_collision` already knows how to
// resolve, not because collision knows what a projectile is. Hitting a
// creature is in sys_collision.odin with the rest of the entity-vs-entity
// work, for the same reason - it is one more question asked of the shared
// broadphase.

// Reads intent and weapon, spawns projectiles. It runs before movement so a
// shot is integrated on the tick it was fired rather than sitting still for
// one step.
//
// The direction is the shooter's own velocity, normalised. A shooter standing
// still has no direction to give, so it falls back to `facing` - which is
// exactly what facing is for, being the last direction that was real.
weapon_system :: proc(s: ^State, dt: f32) {
	for &weapon, i in s.combat.weapon.dense {
		e := s.combat.weapon.owners[i]

		weapon.cooldown = max(0, weapon.cooldown - dt)

		intent := ecs.get(&s.control.intent, e)
		if intent == nil || !intent.fire_requested {
			continue
		}
		// Consumed whether or not the shot happens, for the same reason
		// `movement_system` consumes a jump: a held key is one shot, and two
		// catch-up steps in one frame must not fire twice.
		intent.fire_requested = false
		if weapon.cooldown > 0 {
			continue
		}

		pos := ecs.get(&s.spatial.position, e)
		if pos == nil {
			continue
		}
		col := ecs.get_or(&s.spatial.collider, e, Collider{})
		vel := ecs.get_or(&s.spatial.velocity, e, Vec2{})

		dir := direction_of(vel)
		if dir == {} {
			dir = {f32(ecs.get_or(&s.spatial.facing, e, Facing(1))), 0}
		}

		weapon.cooldown = WEAPON_COOLDOWN

		// From the centre of the shooter, pushed out far enough to clear its
		// own box. The owner is excluded from damage anyway, but starting
		// inside a wall-hugging shooter would resolve the fireball backwards.
		fire_col := entity_definitions[.Fireball].collider
		centre := pos^ + col.size * 0.5 - fire_col * 0.5
		muzzle := centre + dir * (max(col.size.x, col.size.y) * 0.5 + fire_col.x)

		spawn_fireball(s, muzzle, dir * FIREBALL_SPEED, e)
		append(&s.events.sounds, Sound_Request{sound = .Fire, position = muzzle})
	}
}

// The zero vector has no direction; every other vector has one of unit length.
@(private)
direction_of :: proc(v: Vec2) -> Vec2 {
	length := math.sqrt(v.x * v.x + v.y * v.y)
	if length < 0.001 {
		return {}
	}
	return v / length
}

// Gravity and lifetime for everything in flight.
//
// Gravity is applied here rather than in `movement_system` because that system
// is driven by `Movement`, which means "moves under its own power" - a
// fireball does not, it is thrown once and then only physics acts on it. The
// pull itself still comes from the definition table, so a heavier projectile
// is a new row and not a new system.
//
// Expiry marks first and destroys after, like `consequences_system`:
// destroying inline would swap-and-pop the array being iterated. Both use the
// shared `pending_destroy` buffer - see state.odin.
projectile_system :: proc(s: ^State, dt: f32) {
	for &proj, i in s.combat.projectile.dense {
		e := s.combat.projectile.owners[i]

		proj.life -= dt
		if proj.life <= 0 {
			destroy_pending(s, e)
			continue
		}

		vel := ecs.get(&s.spatial.velocity, e)
		if vel == nil {
			continue
		}
		params := &entity_definitions[ecs.get_or(&s.identity.kind, e, Entity_Kind.Fireball)].movement
		vel.y = min(vel.y + params.gravity * dt, params.max_fall_speed)
	}

	flush_pending_destroys(s)
}
