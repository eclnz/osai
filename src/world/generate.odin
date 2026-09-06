package world

// Procedural generation is not a system. It runs once per chunk, outputs a
// tile array and spawn requests, and then it is gone. Nothing keeps a
// reference to it and no per-frame code calls into it.
//
// Ordered passes: layout -> terrain detail -> populate -> validate.

// Not every kind is something generation emits: `Fireball` is only ever
// spawned by the simulation. The enum is the shared vocabulary for "which sort
// of thing", and the populate pass simply never rolls one.
Spawn_Kind :: enum u8 {
	Player,
	Walker,
	Coin,
	Fireball,
	Rock,
}

Spawn_Request :: struct {
	kind:     Spawn_Kind,
	position: Vec2,
}

// Surface height in tiles, as a function of world tile x. Chunk-independent
// by construction: it only reads the seed and x.
surface_height :: proc(seed: u64, tile_x: i32) -> i32 {
	base := f32(0)
	rolling := (fbm_1d(seed ~ 0xa17e, f32(tile_x), 96, 3) - 0.5) * 18
	hills := (value_noise_1d(seed ~ 0xbeef, f32(tile_x), 320) - 0.5) * 40
	return i32(base + rolling + hills)
}

// Pass 1 + 2: shape, then detail. One chunk's worth.
generate_chunk :: proc(seed: u64, cc: Chunk_Coord) -> ^Chunk {
	chunk := new(Chunk)
	chunk.coord = cc
	origin := chunk_origin_tile(cc)

	for ly in 0 ..< i32(CHUNK_TILES) {
		for lx in 0 ..< i32(CHUNK_TILES) {
			tx := origin.x + lx
			ty := origin.y + ly
			idx := int(ly) * CHUNK_TILES + int(lx)

			// --- layout: solid below the surface, air above ---
			surface := surface_height(seed, tx)
			tile := Tile.Empty
			if ty > surface {
				depth := ty - surface
				switch {
				case depth <= 1:
					tile = .Grass
				case depth <= 6:
					tile = .Dirt
				case:
					tile = .Stone
				}
			}

			// --- terrain detail: caves carved out of the solid, lava
			// pooling in the deep ones ---
			if tile != .Empty && ty > surface + 3 {
				cave := value_noise_2d(seed ~ 0xca7e, f32(tx), f32(ty) * 1.8, 24)
				if cave > 0.62 {
					tile = .Empty
					if ty > surface + 26 && cave > 0.70 {
						tile = .Lava
					}
				}
			}

			chunk.tiles[idx] = tile
		}
	}
	return chunk
}

// Pass 3: populate. Appends to the caller's queue rather than owning one -
// spawn requests are simulation input, and generation does not get to reach
// into the simulation itself.
populate_chunk :: proc(seed: u64, chunk: ^Chunk, out: ^[dynamic]Spawn_Request) {
	origin := chunk_origin_tile(chunk.coord)

	for lx in 0 ..< i32(CHUNK_TILES) {
		tx := origin.x + lx
		surface := surface_height(seed, tx)

		// Only populate the chunk that actually contains this column's
		// surface, so a column is populated exactly once however many
		// chunks are stacked vertically.
		if chunk_coord_of_tile({tx, surface}).y != chunk.coord.y {
			continue
		}

		roll := hash_unit(seed ~ 0x50f0, tx, surface)
		if roll > 0.97 {
			append(out, Spawn_Request{
				kind = .Walker,
				position = {f32(tx) * TILE_SIZE + TILE_SIZE / 2, f32(surface - 1) * TILE_SIZE},
			})
		} else if roll < 0.04 {
			append(out, Spawn_Request{
				kind = .Coin,
				position = {f32(tx) * TILE_SIZE + TILE_SIZE / 2, f32(surface - 2) * TILE_SIZE},
			})
		}
	}
}

// Pass 4: validate. What the constraints *are* is a gameplay decision and
// deliberately unspecified; this is the mechanism, holding one constraint we
// are confident about: nothing spawns inside solid rock.
//
// Repair rather than reject: a whole chunk is too big a unit to throw away
// because one spawn point is buried.
Constraint_Violation :: struct {
	request: Spawn_Request,
	reason:  string,
}

validate_spawns :: proc(
	t: ^Terrain,
	requests: ^[dynamic]Spawn_Request,
	violations: ^[dynamic]Constraint_Violation,
) {
	write := 0
	for req in requests {
		tc := tile_coord_of_world(req.position)
		buried := is_solid_at(t, tc) || is_solid_at(t, tc + {0, 1})
		if buried {
			// Repair: walk up until there is headroom, give up after a
			// chunk's worth of tiles.
			repaired := false
			for step in i32(1) ..= i32(CHUNK_TILES) {
				probe := tc - {0, step}
				if !is_solid_at(t, probe) && !is_solid_at(t, probe + {0, 1}) {
					r := req
					r.position.y = f32(probe.y) * TILE_SIZE
					requests[write] = r
					write += 1
					repaired = true
					break
				}
			}
			if !repaired && violations != nil {
				append(violations, Constraint_Violation{request = req, reason = "no headroom in column"})
			}
			continue
		}
		requests[write] = req
		write += 1
	}
	resize(requests, write)
}
