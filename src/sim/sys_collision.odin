package sim

import "../ecs"
import "../world"

// Entity vs terrain, then entity vs entity.

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
	// Nudge the far edge inwards: a box whose edge sits exactly on a tile
	// boundary is not touching the tile beyond it.
	hi = world.tile_coord_of_world({box.max.x - 0.001, box.max.y - 0.001})
	return
}

@(private = "file")
AXIS_X :: 0
@(private = "file")
AXIS_Y :: 1

// Snap the entity to the face of the first solid tile it would enter on one
// axis, and kill that component of velocity. A zero `bounce` - what an entity
// without the component gets - means stop dead.
//
// `probe` is where the box is tested, which is not always `pos`: see the
// caller for why the x pass tests against the previous y. The scan runs
// perpendicular-axis outer, resolved-axis inner, which is what lets both
// passes share one procedure.
//
// Returns whether the entity was stopped moving in the positive direction,
// which on y means it landed.
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
			// Reflect only while there is speed worth reflecting; otherwise
			// settle, or the entity shivers on the floor forever.
			reflected := -vel^[axis] * bounce.restitution
			if abs(reflected) > bounce.min_speed {
				vel^[axis] = reflected
				vel^[other] *= 1 - bounce.friction
				// It reversed rather than stopped, so it is not resting on
				// anything.
				return false
			}
			// Too slow to bounce: resting, so the contact drags instead.
			// Linear, so it stops rather than approaching zero forever.
			vel^[axis] = 0
			vel^[other] = move_toward(vel^[other], 0, bounce.rolling * dt)
			return moving_positive
		}
	}
	return false
}

// Rebuilt after terrain resolution so it reflects final positions, and shared
// by every interaction that follows it. On `State` rather than passed down a
// call chain, so each pass is its own row in `SCHEDULE`.
broadphase_system :: proc(s: ^State, dt: f32) {
	s.broadphase = broadphase_build(s)
}

// Axis at a time. X resolves against the entity's previous y so that walking
// into a wall does not also read as landing on the tile above it; y then
// resolves at the corrected x.
terrain_collision :: proc(s: ^State, dt: f32) {
	// One cursor for the pass: consecutive entities are often in the same
	// chunk.
	cur := world.cursor(&s.terrain)

	// Driven off `velocity`, not `position`: nothing without a velocity can
	// collide with static terrain, and position is the least selective array
	// in the game.
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
			// Standing still keeps `landed` false, so probe one pixel below
			// when not moving upwards.
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
// most one broadphase cell across and a chunk is 512 world units, so the loop
// is one iteration in almost every case.
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

		// Hazard is a property of terrain, so ask terrain once rather than
		// re-deriving it from every tile under every entity every tick.
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

// Pairing is by component presence, not by kind: a collector is anything with
// an inventory, an item anything with an item slot. Candidates come from the
// shared broadphase, so a new interaction is a new system asking the same
// grid rather than another loop over two arrays.
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
			// Box first: it is the common rejection, and it keeps the reject
			// path inside one array. `bp.items` is a second stream, and the
			// sparse lookup below a third.
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

// Projectiles against anything damageable - a second small system asking the
// same grid.
//
// Detection only: what a hit costs is `drain_hits`, as a pickup's cost is
// `drain_pickups`. This pass writes no health and destroys nothing.
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
			// No health, no hit: the fireball flies on through.
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
