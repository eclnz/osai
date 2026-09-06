package sim

import "../ecs"
import "../world"

// Breaking terrain. Reads intent and digger, writes tiles.
//
// This is the only system that writes to the terrain arrays, which is the same
// arrangement `drain_damage` has with health: generation fills a chunk once and
// hands it over, and from then on one procedure owns the edits.
//
// Progress is per digger, not per tile. A tile stays one byte, an unloaded
// chunk has nothing to clean up, and two entities working on the same block
// each get their own progress - which is the answer the "who owns this" question
// has anyway, since the effort belongs to the one doing the digging.

// How much of the reach check is spent on the tile itself. The distance is
// measured to the tile's centre, so a tile is in range when its centre is
// within `reach` - half a tile of slack in every direction, which is what makes
// a reach of three tiles feel like three tiles.
@(private = "file")
tile_centre :: proc(tc: world.Tile_Coord) -> Vec2 {
	return {
		(f32(tc.x) + 0.5) * TILE_SIZE,
		(f32(tc.y) + 0.5) * TILE_SIZE,
	}
}

mining_system :: proc(s: ^State, dt: f32) {
	for &digger, i in s.control.digger.dense {
		e := s.control.digger.owners[i]

		intent := ecs.get(&s.control.intent, e)
		if intent == nil || !intent.dig_requested {
			// Letting go abandons the block. Half-dug is not a state the world
			// remembers - it is the digger's, and the digger stopped.
			digger.progress = 0
			continue
		}

		pos := ecs.get(&s.spatial.position, e)
		if pos == nil {
			continue
		}
		col := ecs.get_or(&s.spatial.collider, e, Collider{})
		centre := pos^ + col.size * 0.5

		target := world.tile_coord_of_world(intent.aim)
		tile := world.tile_at(&s.terrain, target)
		if !world.is_breakable_tile(tile) {
			digger.progress = 0
			continue
		}

		// Out of reach is not an error and not a special case: it is simply
		// not progress. Squared, to keep a square root out of a per-tick loop.
		to_tile := tile_centre(target) - centre
		if to_tile.x * to_tile.x + to_tile.y * to_tile.y > digger.reach * digger.reach {
			digger.progress = 0
			continue
		}

		// Switching blocks starts again. The alternative - carrying progress
		// from one tile to the next - would let a player sweep the aim across a
		// wall and break the last block instantly.
		if target != digger.target {
			digger.target = target
			digger.progress = 0
		}

		digger.progress += digger.speed * dt
		if digger.progress < world.tile_definitions[tile].hardness {
			continue
		}

		world.set_tile(&s.terrain, target, .Empty)
		digger.progress = 0

		// What the block leaves behind goes through the spawn queue like any
		// other spawn, so it is picked up by the inventory system that already
		// exists rather than by anything that knows what mining is.
		append(&s.events.spawns, Spawn_Request{kind = .Rock, position = tile_centre(target)})
		append(&s.events.sounds, Sound_Request{sound = .Break, position = tile_centre(target)})
	}
}
