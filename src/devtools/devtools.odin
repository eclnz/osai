package devtools

import "../ecs"
import "../sim"
import "core:time"

// Measurement and load generation.
//
// None of this is the game. It exists so that claims about performance can be
// checked instead of argued about, and it lives in its own package so that
// `main` stays a harness and `sim` stays free of anything that only a
// developer would ever run.

// Accumulates a repeated interval: a frame's work, a tick loop, a system.
//
// Deliberately measures a span you choose rather than wall-clock elapsed. The
// interesting number is usually the work, not the wait - a frame that ends by
// blocking on vsync reports the display's refresh rate, which says nothing
// about how much headroom the frame had.
Stopwatch :: struct {
	started: time.Tick,
	total:   time.Duration,
	peak:    time.Duration,
	count:   int,
}

begin :: proc(sw: ^Stopwatch) {
	sw.started = time.tick_now()
}

end :: proc(sw: ^Stopwatch) {
	d := time.tick_since(sw.started)
	sw.total += d
	sw.peak = max(sw.peak, d)
	sw.count += 1
}

// Mean and peak of one interval, in microseconds. Zero samples reads as zero
// rather than dividing by it.
mean_us :: proc(sw: Stopwatch) -> f64 {
	if sw.count == 0 {
		return 0
	}
	return time.duration_microseconds(sw.total) / f64(sw.count)
}

peak_us :: proc(sw: Stopwatch) -> f64 {
	return time.duration_microseconds(sw.peak)
}

// Implied rate if nothing else paced the loop.
mean_hz :: proc(sw: Stopwatch) -> f64 {
	us := mean_us(sw)
	if us == 0 {
		return 0
	}
	return 1e6 / us
}

// Spread a population across the resident region: walkers to load movement,
// collision and AI, coins to load the pickup pass. They are dropped above the
// ground and fall onto it.
//
// Callers should hold the player still while measuring, or streaming will
// unload the population being measured against.
spawn_load :: proc(s: ^sim.State, n: int) {
	origin := ecs.get_or(&s.spatial.position, s.player, sim.Vec2{})
	for i in 0 ..< n {
		col := i % 48
		row := i / 48
		p := sim.Vec2 {
			origin.x + f32(col - 24) * sim.TILE_SIZE,
			origin.y - f32(row + 1) * sim.TILE_SIZE * 1.5,
		}
		if i % 2 == 0 {
			sim.spawn_walker(s, p)
		} else {
			sim.spawn_coin(s, p)
		}
	}
}
