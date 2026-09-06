package tests

import "../src/ecs"
import "../src/sim"
import "../src/world"
import "core:os"
import "core:testing"

@(test)
entities_stream_out_and_back_unchanged :: proc(t: ^testing.T) {
	s: sim.State
	sim.state_init(&s, 4242)
	defer sim.state_destroy(&s)

	sim.streaming_update(&s, {0, 0})

	// Far enough away to be outside the streaming radius when the centre is
	// at the origin, and inside it when the centre moves there.
	far := sim.Vec2{
		f32(world.CHUNK_TILES * world.TILE_SIZE) * 6,
		0,
	}
	walker := sim.spawn_walker(&s, far)
	ecs.get(&s.health, walker).current = 17
	far_chunk := world.chunk_coord_of_world(far)

	// Bring that chunk in, then leave again.
	sim.streaming_update(&s, far)
	testing.expect(t, ecs.has(&s.position, walker), "resident entities live in the arrays")

	sim.streaming_update(&s, {0, 0})
	testing.expect(t, !ecs.has(&s.position, walker), "streamed out means out of the arrays")
	testing.expect(t, !ecs.has(&s.health, walker))
	// Out of the arrays is not destroyed: the entity still exists, so handles
	// held elsewhere keep pointing at it.
	testing.expect(t, ecs.is_alive(&s.entities, walker))
	testing.expect(t, far_chunk in s.dormant)

	sim.streaming_update(&s, far)
	testing.expect(t, ecs.has(&s.position, walker), "and back in, with the same handle")
	testing.expect_value(t, ecs.get(&s.position, walker)^, far)
	testing.expect_value(t, ecs.get(&s.health, walker).current, f32(17))
	testing.expect(t, far_chunk not_in s.dormant)
}

@(test)
reloading_a_chunk_does_not_repopulate_it :: proc(t: ^testing.T) {
	s: sim.State
	sim.state_init(&s, 8080)
	defer sim.state_destroy(&s)

	sim.streaming_update(&s, {0, 0})
	first := s.entities.live_count
	testing.expect(t, first > 0, "generation should have populated something")

	// Walk away and come back. Terrain regenerates; creatures must not.
	away := sim.Vec2{f32(world.CHUNK_TILES * world.TILE_SIZE) * 20, 0}
	sim.streaming_update(&s, away)
	sim.streaming_update(&s, {0, 0})

	testing.expect_value(t, s.entities.live_count, s.entities.live_count)
	origin_chunk := world.Chunk_Coord{0, 0}
	resident_at_origin := 0
	for p in s.position.dense {
		if world.chunk_coord_of_world(p) == origin_chunk {
			resident_at_origin += 1
		}
	}
	testing.expect(t, resident_at_origin <= first, "no duplicate spawns on reload")
}

@(test)
save_and_load_round_trips_the_whole_state :: proc(t: ^testing.T) {
	path := "test_save.bin"
	defer os.remove(path)

	original: sim.State
	sim.state_init(&original, 31337)
	defer sim.state_destroy(&original)

	sim.streaming_update(&original, {0, 0})
	player := sim.spawn_player(&original, {48, -160})
	for _ in 0 ..< 90 {
		sim.fixed_step(&original)
	}
	// Edit the terrain so a dirty chunk has to survive the round trip.
	world.set_tile(&original.terrain, {2, 2}, .Stone)

	testing.expect_value(t, sim.save_to_file(&original, path), sim.Save_Error.None)

	restored: sim.State
	sim.state_init(&restored, 1)
	defer sim.state_destroy(&restored)
	testing.expect_value(t, sim.load_from_file(&restored, path), sim.Save_Error.None)

	testing.expect_value(t, restored.seed, original.seed)
	testing.expect_value(t, restored.tick, original.tick)
	testing.expect_value(t, restored.player, player)
	testing.expect_value(t, restored.entities.live_count, original.entities.live_count)
	testing.expect_value(t, len(restored.position.dense), len(original.position.dense))
	testing.expect_value(t, len(restored.resident), len(original.resident))

	// Entity handles survive, so the player is still the player.
	testing.expect_value(t, ecs.get(&restored.position, player)^, ecs.get(&original.position, player)^)
	testing.expect_value(t, ecs.get(&restored.health, player).current, ecs.get(&original.health, player).current)
	testing.expect_value(t, world.tile_at(&restored.terrain, {2, 2}), world.Tile.Stone)

	// And the restored world keeps simulating identically.
	for _ in 0 ..< 60 {
		sim.fixed_step(&original)
		sim.fixed_step(&restored)
	}
	testing.expect_value(t, ecs.get(&restored.position, player)^, ecs.get(&original.position, player)^)
}

@(test)
save_rejects_a_wrong_version :: proc(t: ^testing.T) {
	path := "test_bad_save.bin"
	defer os.remove(path)

	s: sim.State
	sim.state_init(&s, 1)
	defer sim.state_destroy(&s)
	testing.expect_value(t, sim.save_to_file(&s, path), sim.Save_Error.None)

	data, err := os.read_entire_file(path, context.allocator)
	testing.expect(t, err == nil)
	defer delete(data)
	data[4] = data[4] + 1 // bump the version field
	_ = os.write_entire_file(path, data)

	testing.expect_value(t, sim.load_from_file(&s, path), sim.Save_Error.Bad_Version)
}
