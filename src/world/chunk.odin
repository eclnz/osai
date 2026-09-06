package world

// Chunked flat arrays of tile IDs. Collision against terrain is arithmetic:
// divide a position by the tile size and look up the cell.

CHUNK_TILES :: 32
CHUNK_AREA :: CHUNK_TILES * CHUNK_TILES

Chunk_Coord :: distinct [2]i32
Tile_Coord :: distinct [2]i32

Chunk :: struct {
	coord: Chunk_Coord,
	tiles: [CHUNK_AREA]Tile,
	// Set by any write. Only dirty chunks are saved; the rest regenerate
	// from the seed, which is why generation has to be deterministic.
	dirty: bool,
	// Whether any tile here has a non-zero `hazard`. Derived, never saved -
	// `insert_chunk` recomputes it for every chunk entering the terrain, so
	// no producer can forget.
	//
	// Hazard is rare, so this lets a pass asking "is anything standing in
	// lava" answer no for a whole chunk instead of reading every tile under
	// every entity.
	any_hazard: bool,
}

// Recomputed rather than maintained: the only callers are insertion and the
// rare write that removes the last hazard tile.
chunk_recompute_hazard :: proc(chunk: ^Chunk) {
	chunk.any_hazard = false
	for tile in chunk.tiles {
		if tile_definitions[tile].hazard > 0 {
			chunk.any_hazard = true
			return
		}
	}
}

Terrain :: struct {
	chunks: map[Chunk_Coord]^Chunk,
	seed:   u64,
	// Bumped by every tile write. Anything caching a derived answer about
	// terrain stores the value it was computed at and recomputes when they
	// differ. One counter for the whole terrain: writes are rare, so making
	// every cache recompute for a tick beats tracking which of them cared.
	//
	// Starts at one, leaving zero to mean "never computed".
	edits:  u32,
}

terrain_init :: proc(t: ^Terrain, seed: u64) {
	t.chunks = make(map[Chunk_Coord]^Chunk)
	t.seed = seed
	t.edits = 1
}

terrain_destroy :: proc(t: ^Terrain) {
	for _, chunk in t.chunks {
		free(chunk)
	}
	delete(t.chunks)
	t^ = {}
}

// Floor division, not truncation: -1 / 32 must be -1, not 0, or the world
// mirrors itself around the origin.
//
// A chunk is a power of two tiles across, so both are one instruction: for a
// signed integer `>>` is an arithmetic shift and rounds toward negative
// infinity, and `a & 31` is the matching non-negative modulo. These sit under
// `cursor_tile_at`, the innermost call of terrain collision, hazard damage, AI
// probing and mining.
//
// The assert keeps the constants honest: a CHUNK_TILES that is not a power of
// two stops compiling rather than silently mirroring the world again.
CHUNK_SHIFT :: 5
CHUNK_MASK :: CHUNK_TILES - 1
#assert(CHUNK_TILES == 1 << CHUNK_SHIFT)

@(private)
floor_div_chunk :: #force_inline proc(a: i32) -> i32 {
	return a >> CHUNK_SHIFT
}

@(private)
floor_mod_chunk :: #force_inline proc(a: i32) -> i32 {
	return a & CHUNK_MASK
}

tile_coord_of_world :: proc(p: Vec2) -> Tile_Coord {
	// Truncation would fold the two tiles either side of the origin into one.
	tx := i32(p.x / TILE_SIZE)
	ty := i32(p.y / TILE_SIZE)
	if p.x < 0 && f32(tx) * TILE_SIZE != p.x {tx -= 1}
	if p.y < 0 && f32(ty) * TILE_SIZE != p.y {ty -= 1}
	return {tx, ty}
}

chunk_coord_of_tile :: proc(tc: Tile_Coord) -> Chunk_Coord {
	return {floor_div_chunk(tc.x), floor_div_chunk(tc.y)}
}

chunk_coord_of_world :: proc(p: Vec2) -> Chunk_Coord {
	return chunk_coord_of_tile(tile_coord_of_world(p))
}

@(private)
tile_index_in_chunk :: proc(tc: Tile_Coord) -> int {
	lx := floor_mod_chunk(tc.x)
	ly := floor_mod_chunk(tc.y)
	return int(ly) * CHUNK_TILES + int(lx)
}

chunk_origin_tile :: proc(cc: Chunk_Coord) -> Tile_Coord {
	return {cc.x * CHUNK_TILES, cc.y * CHUNK_TILES}
}

is_loaded :: proc(t: ^Terrain, cc: Chunk_Coord) -> bool {
	return cc in t.chunks
}

get_chunk :: proc(t: ^Terrain, cc: Chunk_Coord) -> ^Chunk {
	return t.chunks[cc] or_else nil
}

// Unloaded space reads as Empty rather than erroring: systems ask "is this
// solid", and for terrain that is not resident the answer is no.
tile_at :: proc(t: ^Terrain, tc: Tile_Coord) -> Tile {
	chunk := get_chunk(t, chunk_coord_of_tile(tc))
	if chunk == nil {
		return .Empty
	}
	return chunk.tiles[tile_index_in_chunk(tc)]
}

set_tile :: proc(t: ^Terrain, tc: Tile_Coord, tile: Tile) -> bool {
	chunk := get_chunk(t, chunk_coord_of_tile(tc))
	if chunk == nil {
		return false
	}
	idx := tile_index_in_chunk(tc)
	was_hazard := tile_definitions[chunk.tiles[idx]].hazard > 0
	chunk.tiles[idx] = tile
	chunk.dirty = true
	t.edits += 1

	// Exact rather than conservative: adding hazard is a flag set, and only
	// removing the last of it has to look at the rest of the chunk.
	if tile_definitions[tile].hazard > 0 {
		chunk.any_hazard = true
	} else if was_hazard {
		chunk_recompute_hazard(chunk)
	}
	return true
}

is_solid_at :: proc(t: ^Terrain, tc: Tile_Coord) -> bool {
	return is_solid_tile(tile_at(t, tc))
}

// Ownership of the pointer passes to the terrain.
insert_chunk :: proc(t: ^Terrain, chunk: ^Chunk) {
	if existing, ok := t.chunks[chunk.coord]; ok {
		free(existing)
	}
	// Here rather than in each producer: generation and loading both arrive
	// through this door.
	chunk_recompute_hazard(chunk)
	t.chunks[chunk.coord] = chunk
}

remove_chunk :: proc(t: ^Terrain, cc: Chunk_Coord) -> ^Chunk {
	chunk, ok := t.chunks[cc]
	if !ok {
		return nil
	}
	delete_key(&t.chunks, cc)
	return chunk
}

// Residency. A chunk nobody has edited is a pure function of the seed and its
// coordinate, so it can be thrown away and rebuilt. A dirty one cannot.
//
// Here rather than in the caller because these are the pair that balances
// `insert_chunk`: whoever allocates a chunk should free it.

ensure_loaded :: proc(t: ^Terrain, seed: u64, cc: Chunk_Coord) {
	if is_loaded(t, cc) {
		return
	}
	insert_chunk(t, generate_chunk(seed, cc))
}

// Returns whether the chunk was discarded.
discard_if_clean :: proc(t: ^Terrain, cc: Chunk_Coord) -> bool {
	chunk := get_chunk(t, cc)
	if chunk == nil || chunk.dirty {
		return false
	}
	remove_chunk(t, cc)
	free(chunk)
	return true
}

// A tile query that remembers the chunk it last resolved.
Tile_Cursor :: struct {
	terrain: ^Terrain,
	cc:      Chunk_Coord,
	chunk:   ^Chunk,
	primed:  bool,
}

cursor :: proc(t: ^Terrain) -> Tile_Cursor {
	return Tile_Cursor{terrain = t}
}

cursor_tile_at :: proc(c: ^Tile_Cursor, tc: Tile_Coord) -> Tile {
	cc := chunk_coord_of_tile(tc)
	if !c.primed || cc != c.cc {
		c.cc = cc
		c.chunk = get_chunk(c.terrain, cc)
		c.primed = true
	}
	if c.chunk == nil {
		return .Empty
	}
	return c.chunk.tiles[tile_index_in_chunk(tc)]
}

cursor_is_solid_at :: proc(c: ^Tile_Cursor, tc: Tile_Coord) -> bool {
	return is_solid_tile(cursor_tile_at(c, tc))
}

// Resolves through the same cached chunk pointer as a tile read, so asking
// this before reading tiles costs nothing extra when the answer is yes.
cursor_chunk_has_hazard :: proc(c: ^Tile_Cursor, tc: Tile_Coord) -> bool {
	cc := chunk_coord_of_tile(tc)
	if !c.primed || cc != c.cc {
		c.cc = cc
		c.chunk = get_chunk(c.terrain, cc)
		c.primed = true
	}
	return c.chunk != nil && c.chunk.any_hazard
}
