package sim

import "../ecs"
import "core:math"

// Firing and flight. Terrain contact is not here - a fireball bounces because
// it carries a `Bounce` - and neither is hitting a creature, which is one more
// question asked of the shared broadphase in sys_collision.odin.

// Reads intent and weapon, spawns projectiles. Runs before movement, so a shot
// is integrated on the tick it was fired.
//
// Direction is the shooter's velocity, normalised, falling back to `facing`
// when standing still.
weapon_system :: proc(s: ^State, dt: f32) {
	for &weapon, i in s.combat.weapon.dense {
		e := s.combat.weapon.owners[i]

		weapon.cooldown = max(0, weapon.cooldown - dt)

		intent := ecs.get(&s.control.intent, e)
		if intent == nil || !intent.fire_requested {
			continue
		}
		// Consumed whether or not the shot happens: a held key is one shot,
		// and two catch-up steps must not fire twice.
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

		// Pushed clear of the shooter's own box: starting inside a wall-hugging
		// shooter would resolve the fireball backwards.
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

// Gravity and lifetime for everything in flight. Gravity is here rather than
// in `movement_system` because that one is driven by `Movement`, meaning
// "moves under its own power", which a thrown fireball does not. The pull
// still comes from the definition table, so a heavier projectile is a new row.
//
// Marks before destroying: destroying inline would swap-and-pop the array
// being iterated. See `pending_destroy`.
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
