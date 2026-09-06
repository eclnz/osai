package main

import "ecs"
import "render"
import "sim"
import "world"

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
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
	// Drop the vsync hint so the frame rate reports actual capacity rather
	// than the display's refresh rate. Measurement only - not a play mode.
	novsync: bool,
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
	flags := rl.ConfigFlags{.WINDOW_RESIZABLE}
	if !opt.novsync {
		flags += {.VSYNC_HINT}
	}
	rl.SetConfigFlags(flags)
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

	// Frame *work* time, measured up to EndDrawing and so excluding the
	// present. On macOS the compositor paces presentation to the display
	// whatever the vsync hint says, which makes the FPS counter a reading of
	// the panel rather than of the game. This is the number that is not.
	work_total: time.Duration
	work_max: time.Duration

	for !rl.WindowShouldClose() {
		if opt.frames > 0 && frame >= opt.frames {
			break
		}
		frame += 1

		frame_dt := rl.GetFrameTime()
		work_start := time.tick_now()

		// 0. streaming - residency around the player
		player_pos := ecs.get_or(&s.spatial.position, s.player, sim.Vec2{})
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
		work := time.tick_since(work_start)
		work_total += work
		work_max = max(work_max, work)

		rl.EndDrawing()

		// Sound requests are drained by presentation once per frame. There is
		// no audio yet, so this is where they stop.
		clear(&s.events.sounds)
		free_all(context.temp_allocator)

		if opt.screenshot != "" && opt.frames > 0 && frame == opt.frames {
			rl.TakeScreenshot(fmt.ctprintf("%s", opt.screenshot))
		}

		if !ecs.entity_is_alive(&s.entities, s.player) {
			respawn_player(s)
		}
	}

	if frame > 0 {
		mean := time.duration_microseconds(work_total) / f64(frame)
		peak := time.duration_microseconds(work_max)
		fmt.printfln("frames           %v", frame)
		fmt.printfln("frame work       %.0f us mean, %.0f us peak", mean, peak)
		// What the frame rate would be if nothing paced the present. Compare
		// against the FPS counter: if that reads your refresh rate and this
		// reads far higher, the game is idle-waiting, not working.
		fmt.printfln("uncapped         %.0f fps mean, %.0f fps worst", 1e6 / mean, 1e6 / peak)
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
		sim.entity_destroy(s, s.player)
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
		player_pos := ecs.get_or(&s.spatial.position, s.player, sim.Vec2{})
		sim.streaming_update(s, player_pos)

		// Scripted input: walk right, jump every second.
		if intent := ecs.get(&s.control.intent, s.player); intent != nil {
			intent.horizontal = 1
			intent.jump_requested = i % 60 == 0
		}

		sim.fixed_step(s)
		sim.animation_system(s, sim.FIXED_DT)
		clear(&s.events.sounds)
		free_all(context.temp_allocator)

		if !ecs.entity_is_alive(&s.entities, s.player) {
			fmt.printfln("  tick %v: player died, respawning", s.tick)
			respawn_player(s)
		}
	}

	pos := ecs.get_or(&s.spatial.position, s.player, sim.Vec2{})
	health := ecs.get_or(&s.status.health, s.player, sim.Health{})
	anim := ecs.get_or(&s.presentation.animation, s.player, sim.Animation_State{})

	fmt.printfln("tick             %v", s.tick)
	fmt.printfln("player position  %.1f, %.1f", pos.x, pos.y)
	def := sim.definition_of(&s.identity, s.player)
	fmt.printfln("player health    %.1f / %.1f", health.current, def.max_health)
	fmt.printfln("player animation %v frame %v", anim.current, anim.frame)
	fmt.printfln("live entities    %v", s.entities.live_count)
	fmt.printfln("resident chunks  %v", len(s.residency.resident))
	fmt.printfln("dormant chunks   %v", len(s.residency.dormant))
	fmt.printfln("component counts position=%v velocity=%v health=%v item=%v",
		len(s.spatial.position.dense), len(s.spatial.velocity.dense), len(s.status.health.dense), len(s.items.item.dense))

	if inv := ecs.get(&s.items.inventory, s.player); inv != nil {
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
		case arg == "--novsync":
			opt.novsync = true
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
				"osai [--headless] [--ticks=N] [--seed=N] [--load=PATH] [--frames=N] [--screenshot=PATH] [--novsync]",
			)
			os.exit(0)
		case:
			fmt.eprintfln("unknown argument: %v", arg)
			os.exit(1)
		}
	}
	return opt
}
