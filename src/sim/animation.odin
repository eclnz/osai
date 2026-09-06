package sim

import "../ecs"

// Animation is derived where it can be and commanded where it cannot.
//
// Idle, run, jump and fall are all visible in velocity and grounded, so
// nothing has to tell the animation system about them. Hurt and death are
// not, so the systems that cause them write a command plus a priority, and
// this system decides which wins. A system writing an animation command is
// the same shape as it writing to health: a value into an array.

Animation_Id :: enum u8 {
	Idle,
	Run,
	Jump,
	Fall,
	Hurt,
	Death,
}

// Ordered widest-first, and `frame` is a u8 rather than an int.
//
// No animation has more than a handful of frames - the longest in the table
// below is five - so the frame index never needed eight bytes, and an int
// there forced the whole struct to eight-byte alignment. Laid out this way it
// is 12 bytes instead of 24, which halves the array `animation_system` streams
// once per entity per frame.
Animation_State :: struct {
	elapsed:          f32,
	// A command outranks derivation while it is unexpired.
	command_expiry:   f32,
	current:          Animation_Id,
	commanded:        Animation_Id,
	frame:            u8,
	command_priority: u8,
}
#assert(size_of(Animation_State) == 12)

Animation_Definition :: struct {
	frames:     int,
	frame_time: f32,
	loops:      bool,
}

// Indexed by type ID, one entry per type. Not saved - see entity_definitions.
@(rodata)
animation_definitions := [Animation_Id]Animation_Definition {
	.Idle  = {frames = 4, frame_time = 0.20, loops = true},
	.Run   = {frames = 6, frame_time = 0.08, loops = true},
	.Jump  = {frames = 2, frame_time = 0.12, loops = false},
	.Fall  = {frames = 2, frame_time = 0.12, loops = false},
	.Hurt  = {frames = 2, frame_time = 0.10, loops = false},
	.Death = {frames = 5, frame_time = 0.12, loops = false},
}

DERIVED_PRIORITY :: 0

// A command is live for as long as `command_expiry` is positive - there is no
// separate flag. Clearing zeroes the priority too, so an expired command reads
// as "nothing outranks the derived animation" without anyone having to check
// the timer first.
@(private = "file")
clear_command :: proc(anim: ^Animation_State) {
	anim.command_expiry = 0
	anim.command_priority = 0
}

// Burn down one frame of the active command's timer. Clamped rather than left
// slightly negative so that zero is the single representation of "expired".
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

// Step the current animation's clock and set the frame it lands on.
//
// Looping animations wrap and never report completion; non-looping ones hold
// on the last frame, and report `true` on the step that runs past the end.
@(private = "file")
advance_frame :: proc(anim: ^Animation_State, dt: f32) -> (completed: bool) {
	def := animation_definitions[anim.current]
	anim.elapsed += dt
	if def.frame_time <= 0 {
		return false
	}

	// `advanced` stays an int: a non-looping animation held past its end keeps
	// accumulating, and it is only narrowed once it has been bounded by the
	// frame count, which the table keeps well inside a byte.
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

// Runs once per rendered frame
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

		// A non-looping command expires on completion as well as on its
		// timer, whichever comes first.
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
