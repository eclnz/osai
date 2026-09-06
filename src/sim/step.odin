package sim

// The fixed step. AI sits inside it so that a seed fully reproduces a run;
// input stays outside, because it is tied to real frames, and the fixed step
// just reads whatever `intent` currently holds.
//
// Queues drain once per fixed step, so damage applies at a consistent
// simulated rate rather than a frame-rate-dependent one.

FIXED_DT :: f32(1.0) / 60.0

// Cap on how many fixed steps a single frame may run. Without it, a frame
// that takes longer than FIXED_DT to simulate makes the next frame owe even
// more steps, and the game spirals instead of slowing down.
MAX_CATCHUP_STEPS :: 5

fixed_step :: proc(s: ^State) {
	dt := FIXED_DT

	ai_system(s, dt)
	movement_system(s, dt)
	integration_system(s, dt)
	collision_system(s, dt)

	// Fixed drain order. Damage before spawns so an entity that dies this
	// step cannot also drop loot this step - it drops it next step, from a
	// queue append that survives the drain.
	drain_damage(s)
	drain_pickups(s)
	drain_spawns(s)

	consequences_system(s, dt)

	s.tick += 1
}

// Runs as many fixed steps as the accumulator owes, and returns the leftover
// fraction for the renderer to interpolate with.
Accumulator :: struct {
	remainder: f32,
	steps_run: int,
}

advance :: proc(s: ^State, acc: ^Accumulator, frame_dt: f32) -> (alpha: f32) {
	acc.remainder += frame_dt
	acc.steps_run = 0

	for acc.remainder >= FIXED_DT {
		if acc.steps_run >= MAX_CATCHUP_STEPS {
			// Drop the debt rather than trying to pay it: the simulation
			// runs slow for a frame, which is visible, instead of falling
			// further behind every frame, which is fatal.
			acc.remainder = 0
			break
		}
		fixed_step(s)
		acc.remainder -= FIXED_DT
		acc.steps_run += 1
	}

	return acc.remainder / FIXED_DT
}
