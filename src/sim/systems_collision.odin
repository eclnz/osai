package sim

import "../ecs"
import "../world"

// Collision - entity vs terrain, then entity vs entity. Writes `grounded`,

AABB :: struct {
	min: Vec2,
	max: Vec2,
}

aabb_of :: proc(pos: Vec2, col: Collider) -> AABB {
	return AABB{min = pos, max = pos + col.size}
}

overlaps :: proc(a, b: AABB) -> bool {
	return a.min.x < b.max.x && b.min.x < a.max.x && a.min.y < b.max.y && b.min.y < a.max.y
}

@(private)
tile_span :: proc(box: AABB) -> (lo, hi: world.Tile_Coord) {
	lo = world.tile_coord_of_world(box.min)
	// Nudge the far edge inwards: a box whose right edge sits exactly on a
	// tile boundary is not touching the tile beyond it.
	hi = world.tile_coord_of_world({box.max.x - 0.001, box.max.y - 0.001})
	return
}

@(private = "file")
AXIS_X :: 0
@(private = "file")
AXIS_Y :: 1

// Resolve one axis of motion against solid terrain: snap the entity to the
// face of the first solid tile it would enter, and kill that component of
// velocity.
//
// `probe` is where the box is tested, which is not always `pos` - see the
// caller for why the x pass tests against the previous y.
//
// The scan runs perpendicular-axis outer, resolved-axis inner. That is the one
// rule both passes followed when they were written out separately, and it is
// what makes them the same procedure rather than two similar ones.
//
// Returns whether the entity was stopped while moving in the positive
// direction; on the y axis that means it landed on something.
@(private = "file")
sweep_axis :: proc(
	cur: ^world.Tile_Cursor,
	axis: int,
	probe: Vec2,
	pos: ^Vec2,
	vel: ^Vec2,
	col: Collider,
) -> (stopped_positive: bool) {
	if vel^[axis] == 0 {
		return false
	}
	other := 1 - axis
	lo, hi := tile_span(aabb_of(probe, col))
	moving_positive := vel^[axis] > 0

	for o in lo[other] ..= hi[other] {
		for a in lo[axis] ..= hi[axis] {
			tile: world.Tile_Coord
			tile[axis] = a
			tile[other] = o
			if !world.cursor_is_solid_at(cur, tile) {
				continue
			}
			if moving_positive {
				pos^[axis] = f32(a) * TILE_SIZE - col.size[axis]
			} else {
				pos^[axis] = f32(a + 1) * TILE_SIZE
			}
			vel^[axis] = 0
			return moving_positive
		}
	}
	return false
}

collision_system :: proc(s: ^State, dt: f32) {
	terrain_collision(s)
	hazard_damage(s, dt)
	entity_collision(s)
}

// Entity vs terrain, axis at a time. X is resolved against the entity's
// *previous* y so that walking into a wall does not also read as landing on
// the tile above it; Y is then resolved at the corrected x.
terrain_collision :: proc(s: ^State) {
	// One cursor for the whole pass: consecutive entities are often in the
	// same chunk, so it keeps paying off across the loop, not just within it.
	cur := world.cursor(&s.terrain)

	// Driven off `velocity`, not `position`: nothing without a velocity can
	// collide with static terrain, and position is the least selective array
	// in the game - every coin and every prop has one. At 1000 entities that
	// is half the iterations discarded after two wasted lookups each.
	for &vel, i in s.spatial.velocity.dense {
		e := s.spatial.velocity.owners[i]

		pos := ecs.get(&s.spatial.position, e)
		if pos == nil {
			continue
		}
		col := ecs.get(&s.spatial.collider, e)
		if col == nil {
			continue
		}
		prev := ecs.get_or(&s.spatial.previous_position, e, pos^)

		// X is resolved against the entity's *previous* y, so that walking into
		// a wall does not also read as landing on the tile above it.
		sweep_axis(&cur, AXIS_X, {pos.x, prev.y}, pos, &vel, col^)
		landed := sweep_axis(&cur, AXIS_Y, pos^, pos, &vel, col^)

		if g := ecs.get(&s.spatial.grounded, e); g != nil {
			// Standing still on a floor keeps `landed` false, so also probe
			// one pixel below when the entity is not moving upwards.
			if !landed && vel.y >= 0 {
				feet := AABB {
					min = {pos.x + 1, pos.y + col.size.y},
					max = {pos.x + col.size.x - 1, pos.y + col.size.y + 1},
				}
				lo, hi := tile_span(feet)
				probe: for ty in lo.y ..= hi.y {
					for tx in lo.x ..= hi.x {
						if world.cursor_is_solid_at(&cur, {tx, ty}) {
							landed = true
							break probe
						}
					}
				}
			}
			g.on_ground = landed
		}
	}
}

hazard_damage :: proc(s: ^State, dt: f32) {
	cur := world.cursor(&s.terrain)

	for _, i in s.status.health.dense {
		e := s.status.health.owners[i]

		col := ecs.get(&s.spatial.collider, e)
		pos := ecs.get(&s.spatial.position, e)
		if col == nil || pos == nil {
			continue
		}

		box := aabb_of(pos^, col^)
		lo, hi := tile_span(box)
		total: f32
		for ty in lo.y ..= hi.y {
			for tx in lo.x ..= hi.x {
				hazard := world.tile_definitions[world.cursor_tile_at(&cur, {tx, ty})].hazard
				total = max(total, hazard)
			}
		}
		if total > 0 {
			append(&s.events.damage, Damage_Event{target = e, amount = total * dt, source = .Hazard_Tile})
		}
	}
}

// Entity vs entity. Collectors are entities with an inventory; items are
// entities with an item slot. Neither array knows about the other's meaning -
// the pairing lives here, in the one system that cares.
//
// This is the naive product of the two arrays. There is no broadphase yet;
// the spatial grid the spec puts in step 0 is not built.
entity_collision :: proc(s: ^State) {
	if len(s.items.item.dense) == 0 || len(s.items.inventory.dense) == 0 {
		return
	}

	for _, ci in s.items.inventory.dense {
		collector := s.items.inventory.owners[ci]
		c_pos := ecs.get(&s.spatial.position, collector)
		c_col := ecs.get(&s.spatial.collider, collector)
		if c_pos == nil || c_col == nil {
			continue
		}
		c_box := aabb_of(c_pos^, c_col^)

		for slot, ii in s.items.item.dense {
			item_entity := s.items.item.owners[ii]
			i_pos := ecs.get(&s.spatial.position, item_entity)
			i_col := ecs.get(&s.spatial.collider, item_entity)
			if i_pos == nil || i_col == nil {
				continue
			}
			if !overlaps(c_box, aabb_of(i_pos^, i_col^)) {
				continue
			}
			append(&s.events.pickups, Pickup_Event{
				collector   = collector,
				item_entity = item_entity,
				item        = slot.item,
				count       = slot.count,
			})
		}
	}
}
