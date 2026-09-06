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
// `bounce` decides what happens to velocity at the contact. The zero value -
// what every entity without the component gets - is "stop dead", which is the
// behaviour this procedure had before bouncing existed.
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
	bounce: Bounce,
	dt: f32,
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
			// Reflect if the entity bounces and still has the speed to be
			// worth reflecting; otherwise settle, which is the only thing that
			// stops a ball shivering on a floor forever.
			reflected := -vel^[axis] * bounce.restitution
			if abs(reflected) > bounce.min_speed {
				vel^[axis] = reflected
				vel^[other] *= 1 - bounce.friction
				// It reversed rather than stopped, so it is not resting on
				// anything: a bouncing entity is never grounded by this pass.
				return false
			}
			// Too slow to bounce: it is resting against this surface, so the
			// contact is a roll and drags along it instead. Linear, so it
			// actually comes to a stop rather than approaching zero forever.
			vel^[axis] = 0
			vel^[other] = move_toward(vel^[other], 0, bounce.rolling * dt)
			return moving_positive
		}
	}
	return false
}

// One grid, rebuilt after terrain resolution so it reflects final positions,
// and shared by every entity-vs-entity interaction that follows it in the
// step. It lands on `State` rather than being passed down a call chain so that
// each pass is a separate entry in `SCHEDULE` and can be timed on its own.
broadphase_system :: proc(s: ^State, dt: f32) {
	s.broadphase = broadphase_build(s)
}

// Entity vs terrain, axis at a time. X is resolved against the entity's
// *previous* y so that walking into a wall does not also read as landing on
// the tile above it; Y is then resolved at the corrected x.
terrain_collision :: proc(s: ^State, dt: f32) {
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
		// Absent means "stop dead" - see `sweep_axis`.
		bounce := ecs.get_or(&s.spatial.bounce, e, Bounce{})

		// X is resolved against the entity's *previous* y, so that walking into
		// a wall does not also read as landing on the tile above it.
		sweep_axis(&cur, AXIS_X, {pos.x, prev.y}, pos, &vel, col^, bounce, dt)
		landed := sweep_axis(&cur, AXIS_Y, pos^, pos, &vel, col^, bounce, dt)

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

// Whether any chunk the span touches holds hazard at all. A collider is at
// most one broadphase cell across and a chunk is 512 world units, so a box
// spans at most two chunks per axis; the loop is one iteration in almost every
// case, and the cursor caches the chunk the tile scan below then reuses.
@(private = "file")
span_may_be_hazardous :: proc(cur: ^world.Tile_Cursor, lo, hi: world.Tile_Coord) -> bool {
	lo_cc := world.chunk_coord_of_tile(lo)
	hi_cc := world.chunk_coord_of_tile(hi)
	for cy in lo_cc.y ..= hi_cc.y {
		for cx in lo_cc.x ..= hi_cc.x {
			probe := world.Tile_Coord{cx * world.CHUNK_TILES, cy * world.CHUNK_TILES}
			if world.cursor_chunk_has_hazard(cur, probe) {
				return true
			}
		}
	}
	return false
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

		// Hazard is a property of terrain, so ask terrain once instead of
		// re-deriving it from every tile under every entity every tick. Almost
		// always false, and then this entity costs one chunk lookup.
		if !span_may_be_hazardous(&cur, lo, hi) {
			continue
		}

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
// Pairing is by component presence, not by kind: a collector is anything with
// an inventory, an item is anything with an item slot, and neither array knows
// about the other's meaning. Candidates come from the shared broadphase, so a
// new interaction - an arrow against anything with health, say - is a new
// system asking the same grid, not another loop over two arrays.
entity_collision :: proc(s: ^State, dt: f32) {
	bp := &s.broadphase

	if len(s.items.item.dense) == 0 || len(s.items.inventory.dense) == 0 {
		return
	}

	near := make([dynamic]u32, context.temp_allocator)

	for _, ci in s.items.inventory.dense {
		collector := s.items.inventory.owners[ci]
		c_pos := ecs.get(&s.spatial.position, collector)
		c_col := ecs.get(&s.spatial.collider, collector)
		if c_pos == nil || c_col == nil {
			continue
		}
		c_box := aabb_of(c_pos^, c_col^)

		clear(&near)
		broadphase_query(bp, c_box, &near)

		for idx in near {
			// Box first. It is the common rejection - most candidates in a
			// cell are simply not touching - and it keeps the reject path
			// inside one array. `bp.items` is a second stream and is only
			// touched once a candidate actually overlaps; the sparse lookup
			// below is third, for the same reason.
			if !overlaps(c_box, bp.boxes[idx]) {
				continue
			}
			item_entity := bp.items[idx]
			if item_entity == collector {
				continue
			}
			slot := ecs.get(&s.items.item, item_entity)
			if slot == nil {
				continue // near, overlapping, but not a pickup
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

// Projectiles against anything damageable. This is the "an arrow against
// anything with health" the comment above anticipated: a second small system
// asking the same grid, not another loop over two arrays.
//
// Detection only. What a hit costs - the damage, the end of the projectile -
// is `drain_hits`, exactly as `entity_collision` above detects a pickup and
// leaves `drain_pickups` to move the item and destroy it. This pass has no
// business writing health or destroying entities, and it does not.
projectile_collision :: proc(s: ^State, dt: f32) {
	bp := &s.broadphase

	if len(s.combat.projectile.dense) == 0 {
		return
	}

	near := make([dynamic]u32, context.temp_allocator)

	for proj, pi in s.combat.projectile.dense {
		e := s.combat.projectile.owners[pi]
		p_pos := ecs.get(&s.spatial.position, e)
		p_col := ecs.get(&s.spatial.collider, e)
		if p_pos == nil || p_col == nil {
			continue
		}
		p_box := aabb_of(p_pos^, p_col^)

		clear(&near)
		broadphase_query(bp, p_box, &near)

		for idx in near {
			// Box first, as in `entity_collision` above.
			if !overlaps(p_box, bp.boxes[idx]) {
				continue
			}
			target := bp.items[idx]
			if target == e || target == proj.owner {
				continue
			}
			// Damageable is a component question, like everything else here:
			// no health, no hit, and the fireball flies on through.
			if !ecs.has(&s.status.health, target) {
				continue
			}
			append(&s.events.hits, Hit_Event{
				projectile = e,
				target     = target,
				damage     = proj.damage,
				position   = p_box.min + p_col.size * 0.5,
			})
			break
		}
	}
}
