package sim

// Queues drain once per fixed step, so effects apply at a consistent
// simulated rate rather than a frame-rate-dependent one.

FIXED_DT :: f32(1.0) / 60.0

// Without a cap, a frame slower than FIXED_DT leaves the next frame owing
// more steps still, and the game spirals instead of slowing down.
MAX_CATCHUP_STEPS :: 5

// The step as data rather than a sequence of calls, so that devtools can walk
// the same list with a stopwatch instead of keeping a hand-written copy of the
// order that could drift from it.
System :: struct {
	name: string,
	run:  proc(s: ^State, dt: f32),
}

// The order is the frame order from the spec. The collision passes are
// separate rows because they are separate costs; the grid they share lives on
// `State`.
SCHEDULE :: [?]System {
	{"ai", ai_system},
	{"weapon", weapon_system},
	{"mining", mining_system},
	{"movement", movement_system},
	{"projectile", projectile_system},
	{"integration", integration_system},
	{"terrain_collision", terrain_collision},
	{"hazard_damage", hazard_damage},
	{"broadphase", broadphase_system},
	{"entity_collision", entity_collision},
	{"projectile_collision", projectile_collision},
	{"facing", facing_system},
	{"drain_hits", drain_hits},
	{"drain_damage", drain_damage},
	{"drain_pickups", drain_pickups},
	{"drain_spawns", drain_spawns},
	{"consequences", consequences_system},
}

fixed_step :: proc(s: ^State) {
	for sys in SCHEDULE {
		sys.run(s, FIXED_DT)
	}
	s.tick += 1
}

Accumulator :: struct {
	remainder: f32,
	steps_run: int,
}

advance :: proc(s: ^State, acc: ^Accumulator, frame_dt: f32) -> (alpha: f32) {
	acc.remainder += frame_dt
	acc.steps_run = 0

	for acc.remainder >= FIXED_DT {
		if acc.steps_run >= MAX_CATCHUP_STEPS {
			acc.remainder = 0 // Drop the debt rather than trying to pay it
			break
		}
		fixed_step(s)
		acc.remainder -= FIXED_DT
		acc.steps_run += 1
	}

	return acc.remainder / FIXED_DT
}
