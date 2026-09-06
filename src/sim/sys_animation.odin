package sim

import "../ecs"

// Animation is derived where it can be and commanded where it cannot.
//
// Idle, run, jump and fall are visible in velocity and grounded, so nothing
// has to announce them. Hurt and death are not, so whoever causes them writes
// a command plus a priority and this decides which wins.
//
// The one sys_ file with nothing in `SCHEDULE`: animation runs once per
// rendered frame, outside the fixed step.

DERIVED_PRIORITY :: 0

// A command is live while `command_expiry` is positive; there is no separate
// flag. Clearing the priority too means an expired command reads as "nothing
// outranks derivation" without checking the timer.
@(private = "file")
clear_command :: proc(anim: ^Animation_State) {
	anim.command_expiry = 0
	anim.command_priority = 0
}

// Clamped at zero rather than left negative, so expiry has one representation.
@(private = "file")
tick_command :: proc(anim: ^Animation_State, dt: f32) {
	if anim.command_expiry <= 0 {
		return
	}
	anim.command_expiry -= dt
	if anim.command_expiry <= 0 {
		clear_command(anim)
	}
}

// Looping animations wrap and never complete; non-looping ones hold on the
// last frame and report `true` on the step that runs past the end.
@(private = "file")
advance_frame :: proc(anim: ^Animation_State, dt: f32) -> (completed: bool) {
	def := animation_definitions[anim.current]
	anim.elapsed += dt
	if def.frame_time <= 0 {
		return false
	}

	// `advanced` stays an int - a non-looping animation held past its end keeps
	// accumulating - and is narrowed only once bounded by the frame count.
	advanced := int(anim.elapsed / def.frame_time)
	if def.loops {
		anim.frame = u8(advanced % max(1, def.frames))
		return false
	}

	anim.frame = u8(min(advanced, def.frames - 1))
	return advanced >= def.frames
}

command_animation :: proc(s: ^State, e: ecs.Entity, id: Animation_Id, priority: u8, duration: f32) {
	anim := ecs.get(&s.presentation.animation, e)
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

// Runs once per rendered frame.
animation_system :: proc(s: ^State, dt: f32) {
	for &anim, i in s.presentation.animation.dense {
		e := s.presentation.animation.owners[i]

		tick_command(&anim, dt)

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

		completed := advance_frame(&anim, dt)

		// A non-looping command expires on completion as well as on its timer.
		if completed && anim.command_expiry > 0 && anim.current == anim.commanded {
			clear_command(&anim)
		}

	}
}

@(private)
derive_animation :: proc(s: ^State, e: ecs.Entity) -> Animation_Id {
	vel := ecs.get_or(&s.spatial.velocity, e, Vec2{})
	grounded := ecs.get_or(&s.spatial.grounded, e, Grounded{on_ground = true})

	if !grounded.on_ground {
		return vel.y < 0 ? .Jump : .Fall
	}
	return abs(vel.x) > 5 ? .Run : .Idle
}
