package sim

import "../world"
import "../serial"

// Persistence for the terrain.
//
// `world.Terrain` owns its own lifecycle - `world.terrain_init` and
// `terrain_destroy` live over there - so this file is only the serialisation
// adapter. It sits in `sim` rather than in `world` for a mechanical reason:
// `Writer` and `Reader` are sim types, and `world` cannot import `sim` without
// a cycle. Moving the serialisation primitives into a shared package would let
// `world` own this outright, which is the tidier answer whenever a second
// package needs to save something.

// Only dirty chunks are written, each as a full snapshot. A chunk nobody has
// edited is a pure function of the seed and its coordinate, so storing it
// would be storing something we can recompute. Snapshots rather than diffs
// because a diff is smaller and far easier to get wrong.
terrain_save :: proc(w: ^serial.Writer, t: ^world.Terrain) {
	dirty_count := u32(0)
	for _, chunk in t.chunks {
		if chunk.dirty {dirty_count += 1}
	}

	serial.put(w, dirty_count)
	for _, chunk in t.chunks {
		if !chunk.dirty {
			continue
		}
		serial.put(w, chunk.coord)
		for tile in chunk.tiles {serial.put(w, tile)}
	}
}

terrain_load :: proc(r: ^serial.Reader, t: ^world.Terrain) -> bool {
	dirty_count := serial.take(r, u32) or_return
	for _ in 0 ..< dirty_count {
		chunk := new(world.Chunk)
		chunk.coord = serial.take(r, world.Chunk_Coord) or_return
		chunk.dirty = true
		for i in 0 ..< world.CHUNK_AREA {
			chunk.tiles[i] = serial.take(r, world.Tile) or_return
		}
		world.insert_chunk(t, chunk)
	}
	return true
}

// Resident chunks that were not dirty were never written, so regenerate their
// tiles from the seed. Their entities came back with the component arrays, so
// population must not run again - that is what the restored `populated` set in
// the chunks group is for.
terrain_regenerate_resident :: proc(
	t: ^world.Terrain,
	resident: map[world.Chunk_Coord]bool,
	seed: u64,
) {
	for coord in resident {
		world.ensure_loaded(t, seed, coord)
	}
}
