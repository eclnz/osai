package main

import "ecs"
import "render"
import "sim"
import "world"

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

Options :: struct {
	seed:     u64,
	headless: bool,
	ticks:    int,
	width:    i32,
	height:   i32,
	load:     string,
	// Windowed smoke test: run this many frames and quit. 0 means run until
	// the window is closed.
	frames:     int,
	screenshot: string,
}

SAVE_PATH :: "save.bin"

main :: proc() {
	opt := parse_args()

	state: sim.State
	sim.state_init(&state, opt.seed)
	defer sim.state_destroy(&state)

	start_world(&state)

	if opt.headless {
		run_headless(&state, opt.ticks)
		return
	}
	run_windowed(&state, opt)
}

// Generation runs once, outputs tiles and spawn requests, and is gone. The
// player is spawned on top of whatever the surface turned out to be.
start_world :: proc(s: ^sim.State) {
	spawn_x := f32(0)
	surface := world.surface_height(s.seed, 0)
	spawn_y := f32(surface - 3) * world.TILE_SIZE

	sim.streaming_update(s, {spawn_x, spawn_y})
	sim.spawn_player(s, {spawn_x, spawn_y})
	// Spawning the player changes the streaming centre, so settle residency
	// around them before the first step runs.
	sim.streaming_update(s, {spawn_x, spawn_y})
}

respawn_player :: proc(s: ^sim.State) {
	surface := world.surface_height(s.seed, 0)
	sim.spawn_player(s, {0, f32(surface - 3) * world.TILE_SIZE})
}

// ------------------------------------------------------------------- loop

run_windowed :: proc(s: ^sim.State, opt: Options) {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
	rl.InitWindow(opt.width, opt.height, "osai")
	defer rl.CloseWindow()
	rl.SetTargetFPS(0) // vsync paces us; the fixed step handles the rest

	r: render.Renderer
	render.renderer_init(&r)
	defer render.renderer_destroy(&r)

	if opt.load != "" {
		if err := sim.load_from_file(s, opt.load); err != .None {
			fmt.eprintfln("load failed: %v", err)
		}
	}

	acc: sim.Accumulator
	alpha := f32(0)
	frame := 0

	for !rl.WindowShouldClose() {
		if opt.frames > 0 && frame >= opt.frames {
			break
		}
		frame += 1

		frame_dt := rl.GetFrameTime()

		// 0. streaming - residency around the player
		player_pos := ecs.get_or(&s.position, s.player, sim.Vec2{})
		sim.streaming_update(s, player_pos)

		// 1. input - devices to intent
		input_system(s)
		handle_hotkeys(s)

		// 2..7. fixed steps, repeated until caught up
		alpha = sim.advance(s, &acc, frame_dt)
		input_end_frame(s, acc.steps_run)

		// 8. animation - resolves command against derivation, writes sprite
		sim.animation_system(s, frame_dt)

		// 9. interpolation - previous + current + accumulator fraction
		render.interpolate(&r, s, alpha)
		render.follow(&r, s, 0.18)

		// 10. rendering - reads only
		render.draw(&r, s)
		render.draw_debug(&r, s, alpha, acc.steps_run)
		rl.EndDrawing()

		// Sound requests are drained by presentation once per frame. There is
		// no audio yet, so this is where they stop.
		clear(&s.events.sounds)
		free_all(context.temp_allocator)

		if opt.screenshot != "" && opt.frames > 0 && frame == opt.frames {
			rl.TakeScreenshot(fmt.ctprintf("%s", opt.screenshot))
		}

		if !ecs.is_alive(&s.entities, s.player) {
			respawn_player(s)
		}
	}
}

handle_hotkeys :: proc(s: ^sim.State) {
	if rl.IsKeyPressed(.F5) {
		err := sim.save_to_file(s, SAVE_PATH)
		fmt.printfln("save %v -> %v", SAVE_PATH, err)
	}
	if rl.IsKeyPressed(.F9) {
		err := sim.load_from_file(s, SAVE_PATH)
		fmt.printfln("load %v -> %v", SAVE_PATH, err)
	}
	if rl.IsKeyPressed(.R) {
		sim.destroy_entity(s, s.player)
		respawn_player(s)
	}
}

// ---------------------------------------------------------------- headless
//
// The simulation does not need a window, which is the point of keeping
// raylib out of `sim` entirely. This runs the same fixed step with a scripted
// intent, so a seed and a tick count fully describe a run.

run_headless :: proc(s: ^sim.State, ticks: int) {
	fmt.printfln("headless: seed %v, %v ticks", s.seed, ticks)

	for i in 0 ..< ticks {
		player_pos := ecs.get_or(&s.position, s.player, sim.Vec2{})
		sim.streaming_update(s, player_pos)

		// Scripted input: walk right, jump every second.
		if intent := ecs.get(&s.intent, s.player); intent != nil {
			intent.horizontal = 1
			intent.jump_requested = i % 60 == 0
		}

		sim.fixed_step(s)
		sim.animation_system(s, sim.FIXED_DT)
		clear(&s.events.sounds)
		free_all(context.temp_allocator)

		if !ecs.is_alive(&s.entities, s.player) {
			fmt.printfln("  tick %v: player died, respawning", s.tick)
			respawn_player(s)
		}
	}

	pos := ecs.get_or(&s.position, s.player, sim.Vec2{})
	health := ecs.get_or(&s.health, s.player, sim.Health{})
	anim := ecs.get_or(&s.animation, s.player, sim.Animation_State{})

	fmt.printfln("tick             %v", s.tick)
	fmt.printfln("player position  %.1f, %.1f", pos.x, pos.y)
	fmt.printfln("player health    %.1f / %.1f", health.current, health.max)
	fmt.printfln("player animation %v frame %v", anim.current, anim.frame)
	fmt.printfln("live entities    %v", s.entities.live_count)
	fmt.printfln("resident chunks  %v", len(s.resident))
	fmt.printfln("dormant chunks   %v", len(s.dormant))
	fmt.printfln("component counts position=%v velocity=%v health=%v item=%v",
		len(s.position.dense), len(s.velocity.dense), len(s.health.dense), len(s.item.dense))

	if inv := ecs.get(&s.inventory, s.player); inv != nil {
		for slot in inv.slots {
			if slot.item != .None {
				fmt.printfln("inventory        %v x%v", slot.item, slot.count)
			}
		}
	}
}

// -------------------------------------------------------------------- args

parse_args :: proc() -> Options {
	opt := Options {
		seed   = 0x05a1,
		ticks  = 600,
		width  = 1280,
		height = 720,
	}

	for arg in os.args[1:] {
		switch {
		case arg == "--headless":
			opt.headless = true
		case strings.has_prefix(arg, "--seed="):
			opt.seed = u64(strconv.parse_u64(arg[len("--seed="):]) or_else opt.seed)
		case strings.has_prefix(arg, "--ticks="):
			opt.ticks = strconv.parse_int(arg[len("--ticks="):]) or_else opt.ticks
		case strings.has_prefix(arg, "--load="):
			opt.load = arg[len("--load="):]
		case strings.has_prefix(arg, "--frames="):
			opt.frames = strconv.parse_int(arg[len("--frames="):]) or_else opt.frames
		case strings.has_prefix(arg, "--screenshot="):
			opt.screenshot = arg[len("--screenshot="):]
		case arg == "--help" || arg == "-h":
			fmt.println(
				"osai [--headless] [--ticks=N] [--seed=N] [--load=PATH] [--frames=N] [--screenshot=PATH]",
			)
			os.exit(0)
		case:
			fmt.eprintfln("unknown argument: %v", arg)
			os.exit(1)
		}
	}
	return opt
}
