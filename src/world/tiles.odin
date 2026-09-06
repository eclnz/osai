package world

// Terrain is not entities. A tile is one byte of type ID in a flat array, and
// everything a tile "has" is looked up per type in the table below: ten
// thousand stone tiles cost ten thousand bytes and one table entry.

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
	// Seconds of sustained digging to break it. Zero means unbreakable, which
	// is what empty space and lava are.
	hardness: f32,
	tint:   [4]u8,
}

// Indexed by type ID. Not saved - this is the game, not the state. The
// enumerated array makes the compiler check every case is filled in;
// `@(rodata)` puts it in read-only memory, with the caveats on
// entity_definitions.
@(rodata)
tile_definitions := [Tile]Tile_Definition {
	.Empty = {solid = false, hazard = 0, hardness = 0, tint = {0, 0, 0, 0}},
	.Dirt  = {solid = true, hazard = 0, hardness = 0.35, tint = {104, 76, 52, 255}},
	.Grass = {solid = true, hazard = 0, hardness = 0.45, tint = {86, 137, 68, 255}},
	.Stone = {solid = true, hazard = 0, hardness = 1.20, tint = {96, 100, 108, 255}},
	.Lava  = {solid = false, hazard = 24, hardness = 0, tint = {206, 84, 40, 255}},
}

is_solid_tile :: proc(t: Tile) -> bool {
	return tile_definitions[t].solid
}

// A property of the type, like everything else a tile "has".
is_breakable_tile :: proc(t: Tile) -> bool {
	return tile_definitions[t].hardness > 0
}
