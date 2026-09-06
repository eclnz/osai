package sim

import "../ecs"
import "../world"
import "core:os"

// State is already flat arrays, so saving is writing them out.
//
// Saved:     entity slots and generations, every component array, dormant
//            entities, and dirty chunks (full snapshots, not diffs).
// Not saved: definition tables, render positions, event queues. Those are
//            either the game rather than the state, derived, or frame-scoped.

SAVE_MAGIC :: u32(0x4941534f) // "OSAI"

// Version number in the file, because new component arrays will break old
// saves and it is better to say so than to read garbage.
SAVE_VERSION :: u32(1)

Save_Error :: enum {
	None,
	Cannot_Write,
	Cannot_Read,
	Bad_Magic,
	Bad_Version,
	Truncated,
}

// ------------------------------------------------------------------ writer

Writer :: struct {
	buf: [dynamic]u8,
}

@(private)
put :: proc(w: ^Writer, value: $T) {
	// Every saved type is POD, so its bytes are its state. That is a property
	// of the component types, not of this procedure - a component holding a
	// pointer would compile here and produce a corrupt save.
	v := value
	bytes := transmute(^[size_of(T)]u8)(&v)
	append(&w.buf, ..bytes[:])
}

@(private)
put_set :: proc(w: ^Writer, s: ^ecs.Sparse_Set($T)) {
	put(w, u32(len(s.dense)))
	for value, i in s.dense {
		put(w, s.owners[i])
		put(w, value)
	}
}

// ------------------------------------------------------------------ reader

Reader :: struct {
	buf: []u8,
	off: int,
}

@(private)
take :: proc(r: ^Reader, $T: typeid) -> (value: T, ok: bool) {
	if r.off + size_of(T) > len(r.buf) {
		return {}, false
	}
	bytes := transmute(^[size_of(T)]u8)(&value)
	copy(bytes[:], r.buf[r.off:][:size_of(T)])
	r.off += size_of(T)
	return value, true
}

@(private)
take_set :: proc(r: ^Reader, s: ^ecs.Sparse_Set($T)) -> bool {
	n := take(r, u32) or_return
	for _ in 0 ..< n {
		owner := take(r, ecs.Entity) or_return
		value := take(r, T) or_return
		ecs.add(s, owner, value)
	}
	return true
}

// -------------------------------------------------------------------- save

save_to_file :: proc(s: ^State, path: string) -> Save_Error {
	w: Writer
	defer delete(w.buf)

	put(&w, SAVE_MAGIC)
	put(&w, SAVE_VERSION)
	put(&w, s.seed)
	put(&w, s.tick)
	put(&w, s.player)

	// entity slots
	put(&w, u32(len(s.entities.generations)))
	for g in s.entities.generations {put(&w, g)}
	for a in s.entities.alive {put(&w, a)}
	put(&w, u32(len(s.entities.free_list)))
	for f in s.entities.free_list {put(&w, f)}
	put(&w, i64(s.entities.live_count))

	// component arrays
	put_set(&w, &s.position)
	put_set(&w, &s.previous_position)
	put_set(&w, &s.velocity)
	put_set(&w, &s.collider)
	put_set(&w, &s.grounded)
	put_set(&w, &s.intent)
	put_set(&w, &s.movement)
	put_set(&w, &s.ai)
	put_set(&w, &s.health)
	put_set(&w, &s.appearance)
	put_set(&w, &s.animation)
	put_set(&w, &s.sprite)
	put_set(&w, &s.layer)
	put_set(&w, &s.inventory)
	put_set(&w, &s.item)

	// dormant entities, keyed by chunk
	put(&w, u32(len(s.dormant)))
	for coord, list in s.dormant {
		put(&w, coord)
		put(&w, u32(len(list)))
		for d in list {put(&w, d)}
	}

	// chunk bookkeeping
	put(&w, u32(len(s.resident)))
	for coord in s.resident {put(&w, coord)}
	put(&w, u32(len(s.populated)))
	for coord in s.populated {put(&w, coord)}

	// dirty chunks only, full snapshot each. Untouched chunks regenerate
	// from the seed, and a diff would be smaller but far easier to get wrong.
	dirty_count := u32(0)
	for _, chunk in s.terrain.chunks {
		if chunk.dirty {dirty_count += 1}
	}
	put(&w, dirty_count)
	for _, chunk in s.terrain.chunks {
		if !chunk.dirty {
			continue
		}
		put(&w, chunk.coord)
		for tile in chunk.tiles {put(&w, tile)}
	}

	if err := os.write_entire_file(path, w.buf[:]); err != nil {
		return .Cannot_Write
	}
	return .None
}

// -------------------------------------------------------------------- load

// Replaces everything in `s`. The state that comes back is the state that
// went in, including entity handles: generations are restored, so a handle
// saved alongside the world still resolves.
load_from_file :: proc(s: ^State, path: string) -> Save_Error {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return .Cannot_Read
	}
	defer delete(data)

	r := Reader {
		buf = data,
	}

	magic := take(&r, u32) or_else 0
	if magic != SAVE_MAGIC {
		return .Bad_Magic
	}
	version := take(&r, u32) or_else 0
	if version != SAVE_VERSION {
		return .Bad_Version
	}

	seed := take(&r, u64) or_else 0
	state_destroy(s)
	state_init(s, seed)

	tick, tick_ok := take(&r, u64)
	if !tick_ok {return .Truncated}
	s.tick = tick

	player, player_ok := take(&r, ecs.Entity)
	if !player_ok {return .Truncated}
	s.player = player

	if !load_body(s, &r) {
		return .Truncated
	}
	return .None
}

@(private)
load_body :: proc(s: ^State, r: ^Reader) -> bool {
	slot_count := take(r, u32) or_return
	resize(&s.entities.generations, int(slot_count))
	resize(&s.entities.alive, int(slot_count))
	for i in 0 ..< int(slot_count) {
		s.entities.generations[i] = take(r, u32) or_return
	}
	for i in 0 ..< int(slot_count) {
		s.entities.alive[i] = take(r, bool) or_return
	}
	free_count := take(r, u32) or_return
	resize(&s.entities.free_list, int(free_count))
	for i in 0 ..< int(free_count) {
		s.entities.free_list[i] = take(r, u32) or_return
	}
	live := take(r, i64) or_return
	s.entities.live_count = int(live)

	take_set(r, &s.position) or_return
	take_set(r, &s.previous_position) or_return
	take_set(r, &s.velocity) or_return
	take_set(r, &s.collider) or_return
	take_set(r, &s.grounded) or_return
	take_set(r, &s.intent) or_return
	take_set(r, &s.movement) or_return
	take_set(r, &s.ai) or_return
	take_set(r, &s.health) or_return
	take_set(r, &s.appearance) or_return
	take_set(r, &s.animation) or_return
	take_set(r, &s.sprite) or_return
	take_set(r, &s.layer) or_return
	take_set(r, &s.inventory) or_return
	take_set(r, &s.item) or_return

	dormant_chunks := take(r, u32) or_return
	for _ in 0 ..< dormant_chunks {
		coord := take(r, world.Chunk_Coord) or_return
		n := take(r, u32) or_return
		list := make([dynamic]Dormant_Entity)
		for _ in 0 ..< n {
			append(&list, take(r, Dormant_Entity) or_return)
		}
		s.dormant[coord] = list
	}

	resident_count := take(r, u32) or_return
	for _ in 0 ..< resident_count {
		s.resident[take(r, world.Chunk_Coord) or_return] = true
	}
	populated_count := take(r, u32) or_return
	for _ in 0 ..< populated_count {
		s.populated[take(r, world.Chunk_Coord) or_return] = true
	}

	dirty_count := take(r, u32) or_return
	for _ in 0 ..< dirty_count {
		chunk := new(world.Chunk)
		chunk.coord = take(r, world.Chunk_Coord) or_return
		chunk.dirty = true
		for i in 0 ..< world.CHUNK_AREA {
			chunk.tiles[i] = take(r, world.Tile) or_return
		}
		world.insert_chunk(&s.terrain, chunk)
	}

	// Resident chunks that were not dirty were not saved: regenerate their
	// tiles from the seed. Their entities came back with the component
	// arrays, so population must not run again - which is what the
	// `populated` set restored above is for.
	for coord in s.resident {
		if !world.is_loaded(&s.terrain, coord) {
			world.insert_chunk(&s.terrain, world.generate_chunk(s.seed, coord))
		}
	}
	return true
}
