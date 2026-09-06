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
}

Terrain :: struct {
	chunks: map[Chunk_Coord]^Chunk,
	seed:   u64,
}

terrain_init :: proc(t: ^Terrain, seed: u64) {
	t.chunks = make(map[Chunk_Coord]^Chunk)
	t.seed = seed
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
// A chunk is a power of two tiles across, which makes both of these one
// instruction. For a signed integer `>>` is an arithmetic shift, so `a >> 5`
// *is* floor division by 32 - it rounds toward negative infinity, which is the
// behaviour we had to write a branch for when the divisor was a runtime value.
// `a & 31` is the matching floor modulo, non-negative for negative `a` for the
// same reason. The general versions did a division, a modulo and two branches
// per call, and these sit under `cursor_tile_at`, which is the innermost call
// of terrain collision, hazard damage, AI probing and mining.
//
// The assert is what keeps the two constants honest: change CHUNK_TILES to
// something that is not 1 << CHUNK_SHIFT and this stops compiling rather than
// silently mirroring the world again.
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
	// Truncation toward zero would fold the two tiles either side of the
	// origin into one, so go through floor.
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

// Unloaded space reads as Empty rather than erroring. Systems ask "is this
// solid", and the answer for terrain that is not resident is "no".
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
	chunk.tiles[tile_index_in_chunk(tc)] = tile
	chunk.dirty = true
	return true
}

is_solid_at :: proc(t: ^Terrain, tc: Tile_Coord) -> bool {
	return is_solid_tile(tile_at(t, tc))
}

// Insert a chunk the caller has filled in (from generation or from a save).
// Ownership of the pointer passes to the terrain.
insert_chunk :: proc(t: ^Terrain, chunk: ^Chunk) {
	if existing, ok := t.chunks[chunk.coord]; ok {
		free(existing)
	}
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
// coordinate, so it can be thrown away and rebuilt rather than carried around.
// A dirty one cannot - its tiles are no longer derivable - so it stays.
//
// These live here rather than in the caller because they are the pair that
// balances `insert_chunk`: whoever allocates a chunk should be the one that
// frees it, and the "regenerate it from the seed" rule is a fact about how
// terrain works, not about why someone wanted the chunk.

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
