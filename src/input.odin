package main

import "ecs"
import "sim"
import rl "vendor:raylib"

// Input - reads devices, writes `intent` for the player. Nothing else.
//
// It sits outside the fixed step because it is tied to real frames; the fixed
// step just reads whatever `intent` currently holds. It writes the same
// component the AI system writes for everything else, which is why neither
// has to know the other exists.

input_system :: proc(s: ^sim.State) {
	intent := ecs.get(&s.control.intent, s.player)
	if intent == nil {
		return
	}

	horizontal := f32(0)
	if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) {horizontal -= 1}
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) {horizontal += 1}

	intent.horizontal = horizontal

	// Latched, not sampled: a jump pressed between two fixed steps must not
	// be lost, so the flag stays set until a step consumes it.
	if rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.UP) || rl.IsKeyPressed(.W) {
		intent.jump_requested = true
	}
}

// Called after the fixed steps have run. Clearing only once a step has
// actually run gives a jump pressed between steps a frame of grace instead of
// dropping it; the movement system clears the flag itself when it jumps.
input_end_frame :: proc(s: ^sim.State, steps_run: int) {
	if steps_run == 0 {
		return
	}
	if intent := ecs.get(&s.control.intent, s.player); intent != nil {
		intent.jump_requested = false
	}
}
