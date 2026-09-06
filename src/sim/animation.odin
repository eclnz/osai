package sim

import "../ecs"

// Animation is derived where it can be and commanded where it cannot.
//
// Idle, run, jump and fall are all visible in velocity and grounded, so
// nothing has to tell the animation system about them. Hurt and death are
// not, so the systems that cause them write a command plus a priority, and
// this system decides which wins. A system writing an animation command is
// the same shape as it writing to health: a value into an array.

Animation_Definition :: struct {
	frames:     int,
	frame_time: f32,
	loops:      bool,
}

// Indexed by type ID, one entry per type. Not saved.
animation_definitions := [Animation_Id]Animation_Definition {
	.Idle  = {frames = 4, frame_time = 0.20, loops = true},
	.Run   = {frames = 6, frame_time = 0.08, loops = true},
	.Jump  = {frames = 2, frame_time = 0.12, loops = false},
	.Fall  = {frames = 2, frame_time = 0.12, loops = false},
	.Hurt  = {frames = 2, frame_time = 0.10, loops = false},
	.Death = {frames = 5, frame_time = 0.12, loops = false},
}

// Frame size in the (not yet existent) sprite sheet. Sprite rectangles are
// computed against it so the renderer has something real to read.
FRAME_W :: 16
FRAME_H :: 24

// Derived animations all sit at priority 0, so any command outranks them.
// Priority is what stops the run derivation stomping a hurt animation on the
// next frame.
DERIVED_PRIORITY :: 0

command_animation :: proc(s: ^State, e: ecs.Entity, id: Animation_Id, priority: u8, duration: f32) {
	anim := ecs.get(&s.animation, e)
	if anim == nil {
		return
	}
	if anim.command_expiry > 0 && anim.command_priority > priority {
		return // an existing, higher-priority command holds
	}
	anim.commanded = id
	anim.command_priority = priority
	anim.command_expiry = duration
}

// Runs once per rendered frame, not per fixed step: it is presentation, and
// nothing in the simulation reads what it writes.
animation_system :: proc(s: ^State, dt: f32) {
	for &anim, i in s.animation.dense {
		e := s.animation.owners[i]

		if anim.command_expiry > 0 {
			anim.command_expiry -= dt
			if anim.command_expiry <= 0 {
				anim.command_expiry = 0
				anim.command_priority = 0
			}
		}

		derived := derive_animation(s, e)
		wanted := derived
		if anim.command_expiry > 0 && anim.command_priority > DERIVED_PRIORITY {
			wanted = anim.commanded
		}

		if wanted != anim.current {
			anim.current = wanted
			anim.elapsed = 0
			anim.frame = 0
		}

		def := animation_definitions[anim.current]
		anim.elapsed += dt
		if def.frame_time > 0 {
			advanced := int(anim.elapsed / def.frame_time)
			if def.loops {
				anim.frame = advanced % max(1, def.frames)
			} else {
				anim.frame = min(advanced, def.frames - 1)
				// A non-looping command expires on completion as well as on
				// its timer, whichever comes first.
				if anim.command_expiry > 0 &&
				   anim.current == anim.commanded &&
				   advanced >= def.frames {
					anim.command_expiry = 0
					anim.command_priority = 0
				}
			}
		}

		if sprite := ecs.get(&s.sprite, e); sprite != nil {
			sprite.source = Rect {
				x = f32(anim.frame * FRAME_W),
				y = f32(int(anim.current) * FRAME_H),
				w = FRAME_W,
				h = FRAME_H,
			}
			// Facing is sticky: it only changes while actually moving, so an
			// entity that stops does not snap back to facing right.
			vel := ecs.get_or(&s.velocity, e, Vec2{})
			if vel.x < -1 {
				sprite.flip_x = true
			} else if vel.x > 1 {
				sprite.flip_x = false
			}
		}
	}
}

@(private)
derive_animation :: proc(s: ^State, e: ecs.Entity) -> Animation_Id {
	vel := ecs.get_or(&s.velocity, e, Vec2{})
	grounded := ecs.get_or(&s.grounded, e, Grounded{on_ground = true})

	if !grounded.on_ground {
		return vel.y < 0 ? .Jump : .Fall
	}
	return abs(vel.x) > 5 ? .Run : .Idle
}
