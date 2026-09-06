package world

// Chunked flat arrays of tile IDs. Collision against terrain is arithmetic:
// divide a position by the tile size and look up the cell.

CHUNK_TILES :: 32
CHUNK_AREA :: CHUNK_TILES * CHUNK_TILES

Chunk_Coord :: [2]i32
Tile_Coord :: [2]i32

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
@(private)
floor_div :: proc(a, b: i32) -> i32 {
	q := a / b
	if (a % b != 0) && ((a < 0) != (b < 0)) {
		q -= 1
	}
	return q
}

@(private)
floor_mod :: proc(a, b: i32) -> i32 {
	m := a % b
	if m != 0 && ((m < 0) != (b < 0)) {
		m += b
	}
	return m
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
	return {floor_div(tc.x, CHUNK_TILES), floor_div(tc.y, CHUNK_TILES)}
}

chunk_coord_of_world :: proc(p: Vec2) -> Chunk_Coord {
	return chunk_coord_of_tile(tile_coord_of_world(p))
}

@(private)
tile_index_in_chunk :: proc(tc: Tile_Coord) -> int {
	lx := floor_mod(tc.x, CHUNK_TILES)
	ly := floor_mod(tc.y, CHUNK_TILES)
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
