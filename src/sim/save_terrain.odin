package sim

import "../world"
import "../serial"

// Terrain persistence. `world` owns the terrain's lifecycle; this is only the
// serialisation adapter, and it could move there now that `serial` is its own
// package - at the cost of `world`'s zero imports.

// Only dirty chunks are written. A chunk nobody has edited is a pure function
// of the seed and its coordinate, so storing it would be storing something we
// can recompute. Full snapshots rather than diffs, which are easier to get
// wrong.
terrain_save :: proc(w: ^serial.Writer, t: ^world.Terrain) {
	dirty_count := u32(0)
	for _, chunk in t.chunks {
		if chunk.dirty {dirty_count += 1}
	}

	// Sorted, so two identical runs save identical bytes - see
	// `sorted_chunk_keys`.
	serial.put(w, dirty_count)
	for coord in sorted_chunk_keys(t.chunks) {
		chunk := t.chunks[coord]
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

// Clean resident chunks were never written, so regenerate them from the seed.
// Their entities came back with the component arrays, so population must not
// run again - that is what the restored `populated` set is for.
terrain_regenerate_resident :: proc(
	t: ^world.Terrain,
	resident: map[world.Chunk_Coord]bool,
	seed: u64,
) {
	for coord in sorted_chunk_keys(resident) {
		world.ensure_loaded(t, seed, coord)
	}
}
