package world

// Terrain is not entities.
//
// A tile is one byte of type ID in a flat array. Everything a tile "has" is
// looked up per *type*, not per instance, in the definition table below.
// Ten thousand stone tiles cost ten thousand bytes and one table entry.

Vec2 :: [2]f32

// World units are pixels. One tile is TILE_SIZE of them.
TILE_SIZE :: 16

Tile :: enum u8 {
	Empty,
	Dirt,
	Grass,
	Stone,
	Lava,
}

Tile_Definition :: struct {
	solid:  bool,
	// Damage per second applied to anything overlapping this tile.
	hazard: f32,
	tint:   [4]u8,
}

// Indexed by type ID, one entry per type. Not saved - this is the game, not
// the state. Odin's enumerated arrays give us the "indexed by type ID" the
// spec asks for, with the compiler checking that every case is filled in.
tile_definitions := [Tile]Tile_Definition {
	.Empty = {solid = false, hazard = 0, tint = {0, 0, 0, 0}},
	.Dirt  = {solid = true, hazard = 0, tint = {104, 76, 52, 255}},
	.Grass = {solid = true, hazard = 0, tint = {86, 137, 68, 255}},
	.Stone = {solid = true, hazard = 0, tint = {96, 100, 108, 255}},
	.Lava  = {solid = false, hazard = 24, tint = {206, 84, 40, 255}},
}

is_solid_tile :: proc(t: Tile) -> bool {
	return tile_definitions[t].solid
}
