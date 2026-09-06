package main

import "ecs"
import "sim"
import rl "vendor:raylib"

// Reads devices, writes `intent` for the player. Outside the fixed step
// because it is tied to real frames; the step reads whatever `intent` holds.
// It writes the same component the AI system writes for everything else, so
// neither has to know the other exists.

// `aim` arrives in world units, which is why the camera comes in: `sim` never
// learns that a screen exists.
input_system :: proc(s: ^sim.State, aim: sim.Vec2) {
	intent := ecs.get(&s.control.intent, s.player)
	if intent == nil {
		return
	}
	intent.aim = aim

	horizontal := f32(0)
	if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) {horizontal -= 1}
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) {horizontal += 1}

	intent.horizontal = horizontal

	// Latched, not sampled: a jump pressed between two fixed steps must not be
	// lost, so the flag stays set until a step consumes it.
	if rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.UP) || rl.IsKeyPressed(.W) {
		intent.jump_requested = true
	}
	if rl.IsKeyPressed(.F) || rl.IsMouseButtonPressed(.RIGHT) {
		intent.fire_requested = true
	}

	// Held, not latched. Nothing consumes it, so it is written every frame,
	// including the frame it goes false.
	intent.dig_requested = rl.IsMouseButtonDown(.LEFT)
}

// Clearing only once a step has actually run gives a jump pressed between
// steps a frame of grace instead of dropping it.
input_end_frame :: proc(s: ^sim.State, steps_run: int) {
	if steps_run == 0 {
		return
	}
	if intent := ecs.get(&s.control.intent, s.player); intent != nil {
		intent.jump_requested = false
		intent.fire_requested = false
	}
}
