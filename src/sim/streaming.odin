package sim

import "../ecs"
import "../serial"
import "../world"

// Streaming is residency, not filtering - so the residency state and the pass
// that maintains it are the same file.
//
// Systems never iterate a list of active IDs - that would be an ID lookup per
// entity per system, which is the thing packed arrays exist to avoid. Instead
// an entity that leaves the active region is copied out of the component
// arrays into a blob attached to its chunk, and removed. Everything still in
// the arrays is active by definition. The blob and its capture/restore live in
// dormant.odin; this file decides *when* they happen.
//
// The entity's *slot* is not freed, so handles held elsewhere stay valid and
// keep pointing at the same entity when it streams back in. `ecs.entity_is_alive`
// answers "does this entity exist", not "is it resident".

// The three maps are only ever written here, which is why they live in this
// file rather than a group file of their own: there is no second party for a
// data/behaviour boundary to protect. `world/chunk.odin` owns the other half
// of the word - tiles and the terrain map. Nothing below holds a tile; these
// borrow that package's `Chunk_Coord` purely as a key.
Residency :: struct {
	dormant: map[world.Chunk_Coord][dynamic]Dormant_Entity,
	resident: map[world.Chunk_Coord]bool,
	// Last centre the residency set was computed for. The wanted set is a pure
	// function of centre and radius, so if neither moved there is nothing to
	// diff - which is what makes the cost land at chunk boundaries rather than
	// on every step.
	center:         world.Chunk_Coord,
	center_radius:  int,
	centered:       bool,
	populated: map[world.Chunk_Coord]bool,
}

residency_init :: proc(res: ^Residency) {
	res.dormant = make(map[world.Chunk_Coord][dynamic]Dormant_Entity)
	res.resident = make(map[world.Chunk_Coord]bool)
	res.populated = make(map[world.Chunk_Coord]bool)
}

residency_destroy :: proc(res: ^Residency) {
	for _, &list in res.dormant {
		delete(list)
	}
	delete(res.dormant)
	delete(res.resident)
	delete(res.populated)
}

residency_save :: proc(w: ^serial.Writer, res: ^Residency) {
	serial.put(w, u32(len(res.dormant)))
	for coord, list in res.dormant {
		serial.put(w, coord)
		serial.put_array(w, list[:])
	}
	serial.put(w, u32(len(res.resident)))
	for coord in res.resident {serial.put(w, coord)}
	serial.put(w, u32(len(res.populated)))
	for coord in res.populated {serial.put(w, coord)}
}

residency_load :: proc(r: ^serial.Reader, res: ^Residency) -> bool {
	dormant_chunks := serial.take(r, u32) or_return
	for _ in 0 ..< dormant_chunks {
		coord := serial.take(r, world.Chunk_Coord) or_return
		list := make([dynamic]Dormant_Entity)
		serial.take_array(r, &list) or_return
		res.dormant[coord] = list
	}
	resident_count := serial.take(r, u32) or_return
	for _ in 0 ..< resident_count {
		res.resident[serial.take(r, world.Chunk_Coord) or_return] = true
	}
	populated_count := serial.take(r, u32) or_return
	for _ in 0 ..< populated_count {
		res.populated[serial.take(r, world.Chunk_Coord) or_return] = true
	}
	return true
}

// How many chunks either side of the centre stay resident.
STREAM_RADIUS :: 2

// Step 0 of the frame. Cost lands at chunk boundaries, which are rare;
// iteration happens every step.
streaming_update :: proc(s: ^State, center: Vec2, radius := STREAM_RADIUS) {
	center_chunk := world.chunk_coord_of_world(center)
	if s.residency.centered &&
	   center_chunk == s.residency.center &&
	   radius == s.residency.center_radius {
		return
	}
	s.residency.center = center_chunk
	s.residency.center_radius = radius
	s.residency.centered = true

	wanted := make(map[world.Chunk_Coord]bool, context.temp_allocator)
	for dy in -i32(radius) ..= i32(radius) {
		for dx in -i32(radius) ..= i32(radius) {
			wanted[center_chunk + {dx, dy}] = true
		}
	}

	// Unload first, so an entity that has walked from one chunk to another
	// is not captured and immediately re-captured.
	to_unload := make([dynamic]world.Chunk_Coord, context.temp_allocator)
	for cc in s.residency.resident {
		if cc not_in wanted {
			append(&to_unload, cc)
		}
	}
	for cc in to_unload {
		unload_chunk(s, cc)
	}

	for cc in wanted {
		if cc not_in s.residency.resident {
			load_chunk(s, cc)
		}
	}
}

load_chunk :: proc(s: ^State, cc: world.Chunk_Coord) {
	if cc in s.residency.resident {
		return
	}

	world.ensure_loaded(&s.terrain, s.seed, cc)

	// Generation runs again on every reload; population does not. The
	// entities it produced the first time are dormant, not gone, and are
	// restored below.
	if cc not_in s.residency.populated {
		s.residency.populated[cc] = true
		chunk := world.get_chunk(&s.terrain, cc)
		requests := make([dynamic]world.Spawn_Request, context.temp_allocator)
		world.populate_chunk(s.seed, chunk, &requests)
		world.validate_spawns(&s.terrain, &requests, nil)
		for req in requests {
			spawn(s, req)
		}
	}

	// Entities that were resident here before are woken exactly as they were.
	if dormant, ok := s.residency.dormant[cc]; ok {
		for d in dormant {
			restore_entity(s, d)
		}
		delete(dormant)
		delete_key(&s.residency.dormant, cc)
	}

	s.residency.resident[cc] = true
}

unload_chunk :: proc(s: ^State, cc: world.Chunk_Coord) {
	if cc not_in s.residency.resident {
		return
	}

	// Collect first: capturing mutates the arrays we are iterating.
	leaving := make([dynamic]ecs.Entity, context.temp_allocator)
	for p, i in s.spatial.position.dense {
		if world.chunk_coord_of_world(p) == cc {
			e := s.spatial.position.owners[i]
			// The player is never streamed out from under the camera.
			if e == s.player {
				continue
			}
			append(&leaving, e)
		}
	}

	if len(leaving) > 0 {
		list, ok := &s.residency.dormant[cc]
		if !ok {
			s.residency.dormant[cc] = make([dynamic]Dormant_Entity)
			list = &s.residency.dormant[cc]
		}
		for e in leaving {
			append(list, capture_entity(s, e))
			detach_all_components(s, e)
		}
	}

	// An edited chunk stays in memory (and, once saving is wired to unload, on
	// disk); a clean one is regenerated on the way back in.
	world.discard_if_clean(&s.terrain, cc)

	delete_key(&s.residency.resident, cc)
}
