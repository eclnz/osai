package devtools

import "../ecs"
import "../sim"

// A per-system breakdown of the fixed step.
//
// This used to be a hand-written mirror of `sim.fixed_step` - a named
// stopwatch per system, in an order that had to be kept in step by eye, and
// which its own comment admitted could drift. It walks `sim.SCHEDULE` now, so
// it cannot: the game and the measurement read the same list.
//
// `streaming` and `animation` are still named separately because they are
// genuinely not in the fixed step - the frame runs them around it.
Profile :: struct {
	streaming: Stopwatch,
	systems:   [len(sim.SCHEDULE)]Stopwatch,
	animation: Stopwatch,
	tick:      Stopwatch,
}

Sample :: struct {
	name:    string,
	mean_us: f64,
	peak_us: f64,
}

// The player is held still: streaming must not unload the population being
// measured, and a scripted walk would make every run measure a different
// stretch of terrain.
profile :: proc(s: ^sim.State, ticks: int) -> Profile {
	p: Profile
	dt := sim.FIXED_DT

	for _ in 0 ..< ticks {
		begin(&p.tick)

		player_pos := ecs.get_or(&s.spatial.position, s.player, sim.Vec2{})
		begin(&p.streaming);sim.streaming_update(s, player_pos);end(&p.streaming)

		if intent := ecs.get(&s.control.intent, s.player); intent != nil {
			intent.horizontal = 0
			intent.jump_requested = false
		}

		for sys, i in sim.SCHEDULE {
			begin(&p.systems[i]);sys.run(s, dt);end(&p.systems[i])
		}
		s.tick += 1

		begin(&p.animation);sim.animation_system(s, dt);end(&p.animation)

		clear(&s.events.sounds)
		free_all(context.temp_allocator)
		end(&p.tick)
	}
	return p
}

// Flat list, so a caller can sort and print without knowing the field names.
samples :: proc(p: Profile, allocator := context.allocator) -> [dynamic]Sample {
	out := make([dynamic]Sample, allocator)
	add :: proc(out: ^[dynamic]Sample, name: string, sw: Stopwatch) {
		append(out, Sample{name = name, mean_us = mean_us(sw), peak_us = peak_us(sw)})
	}
	add(&out, "streaming", p.streaming)
	for sys, i in sim.SCHEDULE {
		add(&out, sys.name, p.systems[i])
	}
	add(&out, "animation", p.animation)
	return out
}
