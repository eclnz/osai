package sim

import "../ecs"
import "../world"

// Each system says what it reads and writes. That contract is the only thing
// holding the frame together, because no system calls another.

// Reads world state, writes `intent`. The player has no `ai` component, so
// this loop never sees it - the input system writes the player's intent.
ai_system :: proc(s: ^State, dt: f32) {
	// One cursor for the pass: consecutive walkers are usually in the same
	// chunk.
	cur := world.cursor(&s.terrain)

	for &ai, i in s.control.ai.dense {
		e := s.control.ai.owners[i]
		intent := ecs.get(&s.control.intent, e)
		if intent == nil {
			continue
		}

		switch ai.behaviour {
		case .Idle:
			intent^ = {}

		case .Patrol:
			pos := ecs.get_or(&s.spatial.position, e, Vec2{})
			col := ecs.get_or(&s.spatial.collider, e, Collider{})
			grounded := ecs.get_or(&s.spatial.grounded, e, Grounded{})

			if grounded.on_ground {
				// Turn around at a wall or at the edge of a ledge.
				ahead_x := ai.facing > 0 ? pos.x + col.size.x + 1 : pos.x - 1
				foot_y := pos.y + col.size.y + 1
				ahead_tile := world.tile_coord_of_world({ahead_x, pos.y + col.size.y * 0.5})
				floor_tile := world.tile_coord_of_world({ahead_x, foot_y})

				// Two integer compares stand in for two chunk lookups. Mining
				// bumps `edits`, so a cached answer cannot outlive the terrain
				// it describes.
				fresh :=
					ai.probe_edits == s.terrain.edits &&
					ai.probe_ahead == ahead_tile &&
					ai.probe_floor == floor_tile
				if !fresh {
					blocked := world.cursor_is_solid_at(&cur, ahead_tile)
					no_floor := !world.cursor_is_solid_at(&cur, floor_tile)
					ai.turn = blocked || no_floor
					ai.probe_edits = s.terrain.edits
					ai.probe_ahead = ahead_tile
					ai.probe_floor = floor_tile
				}
				if ai.turn {
					ai.facing = -ai.facing
				}
			}

			ai.timer += dt
			intent.horizontal = ai.facing
			intent.jump_requested = false
		}
	}
}

// Reads intent, movement params and grounded; writes velocity. It does not
// touch position - keeping the two apart is what makes the step reorderable.
movement_system :: proc(s: ^State, dt: f32) {
	for &intent, i in s.control.intent.dense {
		e := s.control.intent.owners[i]

		mv := ecs.get(&s.control.movement, e)
		if mv == nil {
			continue
		}
		// By pointer: copying would put 24 bytes on the stack per entity per
		// tick.
		params := &entity_definitions[mv.def].movement
		vel := ecs.get(&s.spatial.velocity, e)
		if vel == nil {
			continue
		}
		grounded := ecs.get_or(&s.spatial.grounded, e, Grounded{})

		control := grounded.on_ground ? f32(1) : params.air_control
		target := clamp(intent.horizontal, -1, 1) * params.move_speed
		accel := params.ground_damping * params.move_speed * control * dt
		vel.x = move_toward(vel.x, target, accel)

		if intent.jump_requested && grounded.on_ground {
			vel.y = -params.jump_speed
			// Consume it here, so a held key is one jump and two catch-up
			// steps do not both apply it.
			intent.jump_requested = false
			if g := ecs.get(&s.spatial.grounded, e); g != nil {
				g.on_ground = false
			}
			append(&s.events.sounds, Sound_Request{sound = .Jump, position = ecs.get_or(&s.spatial.position, e, Vec2{})})
		}

		vel.y = min(vel.y + params.gravity * dt, params.max_fall_speed)
	}
}

@(private)
move_toward :: proc(current, target, max_delta: f32) -> f32 {
	delta := target - current
	if abs(delta) <= max_delta {
		return target
	}
	return current + (delta > 0 ? max_delta : -max_delta)
}

// Copies position into previous_position, then applies velocity.
// previous_position exists only so the renderer can interpolate between two
// fixed steps; nothing in the simulation reads it after this.
integration_system :: proc(s: ^State, dt: f32) {
	for &pos, i in s.spatial.position.dense {
		e := s.spatial.position.owners[i]

		if prev := ecs.get(&s.spatial.previous_position, e); prev != nil {
			prev^ = pos
		}
		if vel := ecs.get(&s.spatial.velocity, e); vel != nil {
			pos += vel^ * dt
		}
	}
}

// Orientation from the velocity the entity actually ended up with. Runs after
// collision, so that velocity is final.
//
// Distinct from `AI_State.facing`, which is patrol intent rather than outcome.
facing_system :: proc(s: ^State, dt: f32) {
	for &facing, i in s.spatial.facing.dense {
		e := s.spatial.facing.owners[i]

		vel := ecs.get_or(&s.spatial.velocity, e, Vec2{})
		if vel.x < -1 {
			facing = -1
		} else if vel.x > 1 {
			facing = 1
		}
	}
}
