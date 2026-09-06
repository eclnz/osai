package tests

import "../src/world"
import "core:testing"

@(test)
negative_coordinates_use_floor_division :: proc(t: ^testing.T) {
	// Truncating toward zero would fold the tiles either side of the origin
	// into one and mirror the world.
	testing.expect_value(t, world.tile_coord_of_world({0, 0}), world.Tile_Coord{0, 0})
	testing.expect_value(t, world.tile_coord_of_world({15.9, 0}), world.Tile_Coord{0, 0})
	testing.expect_value(t, world.tile_coord_of_world({16, 0}), world.Tile_Coord{1, 0})
	testing.expect_value(t, world.tile_coord_of_world({-0.5, 0}), world.Tile_Coord{-1, 0})
	testing.expect_value(t, world.tile_coord_of_world({-16, 0}), world.Tile_Coord{-1, 0})
	testing.expect_value(t, world.tile_coord_of_world({-16.5, 0}), world.Tile_Coord{-2, 0})

	testing.expect_value(t, world.chunk_coord_of_tile({0, 0}), world.Chunk_Coord{0, 0})
	testing.expect_value(t, world.chunk_coord_of_tile({31, 31}), world.Chunk_Coord{0, 0})
	testing.expect_value(t, world.chunk_coord_of_tile({32, 0}), world.Chunk_Coord{1, 0})
	testing.expect_value(t, world.chunk_coord_of_tile({-1, -1}), world.Chunk_Coord{-1, -1})
	testing.expect_value(t, world.chunk_coord_of_tile({-32, 0}), world.Chunk_Coord{-1, 0})
	testing.expect_value(t, world.chunk_coord_of_tile({-33, 0}), world.Chunk_Coord{-2, 0})
}

@(test)
tiles_write_and_read_across_chunk_boundaries :: proc(t: ^testing.T) {
	terrain: world.Terrain
	world.terrain_init(&terrain, 1)
	defer world.terrain_destroy(&terrain)

	for cc in ([?]world.Chunk_Coord{{0, 0}, {-1, 0}, {-1, -1}}) {
		world.insert_chunk(&terrain, world.generate_chunk(terrain.seed, cc))
	}

	probes := [?]world.Tile_Coord{{0, 0}, {31, 5}, {-1, 0}, {-32, -1}, {-17, -20}}
	for tc in probes {
		testing.expect(t, world.set_tile(&terrain, tc, .Stone), "chunk should be loaded")
		testing.expect_value(t, world.tile_at(&terrain, tc), world.Tile.Stone)
		testing.expect(t, world.is_solid_at(&terrain, tc))
	}

	// Writing marks the chunk dirty; that flag is what persistence keys off.
	testing.expect(t, world.get_chunk(&terrain, {0, 0}).dirty)

	// Unloaded space reads as empty rather than erroring.
	testing.expect_value(t, world.tile_at(&terrain, {5000, 5000}), world.Tile.Empty)
	testing.expect(t, !world.set_tile(&terrain, {5000, 5000}, .Stone))
}

@(test)
generation_is_seeded_and_order_independent :: proc(t: ^testing.T) {
	// A chunk straddling the surface: one high in the sky is all air whatever
	// the seed, and would pass without testing anything.
	a := world.generate_chunk(1234, {3, 0})
	b := world.generate_chunk(1234, {3, 0})
	defer free(a)
	defer free(b)
	testing.expect(t, a.tiles == b.tiles, "same seed must produce the same chunk")

	c := world.generate_chunk(1235, {3, 0})
	defer free(c)
	testing.expect(t, a.tiles != c.tiles, "a different seed should produce a different chunk")

	// A pure function of (seed, coord): generating neighbours in a different
	// order must not change the result, or the world would depend on how the
	// player wandered.
	before := world.generate_chunk(77, {0, 0})
	defer free(before)
	_ = free_chunk(world.generate_chunk(77, {1, 0}))
	_ = free_chunk(world.generate_chunk(77, {-1, 0}))
	after := world.generate_chunk(77, {0, 0})
	defer free(after)
	testing.expect(t, before.tiles == after.tiles)
}

@(private)
free_chunk :: proc(c: ^world.Chunk) -> bool {
	free(c)
	return true
}

@(test)
validation_lifts_buried_spawns :: proc(t: ^testing.T) {
	terrain: world.Terrain
	world.terrain_init(&terrain, 5)
	defer world.terrain_destroy(&terrain)

	chunk := world.generate_chunk(5, {0, 0})
	// Solid floor across the bottom half, air above.
	for i in 0 ..< world.CHUNK_AREA {
		chunk.tiles[i] = i >= (world.CHUNK_TILES * 16) ? .Stone : .Empty
	}
	world.insert_chunk(&terrain, chunk)

	requests := make([dynamic]world.Spawn_Request)
	defer delete(requests)
	// Buried 4 tiles into the rock.
	append(&requests, world.Spawn_Request{kind = .Coin, position = {8 * 16, 20 * 16}})
	// Already fine.
	append(&requests, world.Spawn_Request{kind = .Walker, position = {8 * 16, 10 * 16}})

	violations := make([dynamic]world.Constraint_Violation)
	defer delete(violations)
	world.validate_spawns(&terrain, &requests, &violations)

	testing.expect_value(t, len(requests), 2)
	testing.expect_value(t, len(violations), 0)
	// Repaired upward until there was headroom, rather than rejected.
	testing.expect(t, requests[0].position.y < 16 * 16)
	testing.expect(t, !world.is_solid_at(&terrain, world.tile_coord_of_world(requests[0].position)))
	testing.expect_value(t, requests[1].position.y, 10 * 16)
}
