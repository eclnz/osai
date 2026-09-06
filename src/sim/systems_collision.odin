package sim

import "../ecs"
import "../world"

// Collision - entity vs terrain, then entity vs entity. Writes `grounded`,
// corrects `position`, and appends to the damage and pickup queues. It does
// not apply damage or move items into inventories; those are drains, and
// keeping them separate is what stops "who runs first" from mattering.
//
// Correction happens inline here rather than in a separate resolution pass.
// That is one of the spec's open questions; the axis-separated resolution
// below is small enough that splitting it would currently buy nothing.

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

collision_system :: proc(s: ^State, dt: f32) {
	terrain_collision(s)
	hazard_damage(s, dt)
	entity_collision(s)
}

// Entity vs terrain, axis at a time. X is resolved against the entity's
// *previous* y so that walking into a wall does not also read as landing on
// the tile above it; Y is then resolved at the corrected x.
terrain_collision :: proc(s: ^State) {
	for &pos, i in s.position.dense {
		e := s.position.owners[i]

		col := ecs.get(&s.collider, e)
		if col == nil {
			continue
		}
		vel := ecs.get(&s.velocity, e)
		if vel == nil {
			// Nothing that does not move can collide with static terrain.
			continue
		}
		prev := ecs.get_or(&s.previous_position, e, pos)

		// --- x ---
		if vel.x != 0 {
			box := aabb_of({pos.x, prev.y}, col^)
			lo, hi := tile_span(box)
			search_x: for ty in lo.y ..= hi.y {
				for tx in lo.x ..= hi.x {
					if !world.is_solid_at(&s.terrain, {tx, ty}) {
						continue
					}
					if vel.x > 0 {
						pos.x = f32(tx) * TILE_SIZE - col.size.x
					} else {
						pos.x = f32(tx + 1) * TILE_SIZE
					}
					vel.x = 0
					break search_x
				}
			}
		}

		// --- y ---
		landed := false
		if vel.y != 0 {
			box := aabb_of(pos, col^)
			lo, hi := tile_span(box)
			search_y: for tx in lo.x ..= hi.x {
				for ty in lo.y ..= hi.y {
					if !world.is_solid_at(&s.terrain, {tx, ty}) {
						continue
					}
					if vel.y > 0 {
						pos.y = f32(ty) * TILE_SIZE - col.size.y
						landed = true
					} else {
						pos.y = f32(ty + 1) * TILE_SIZE
					}
					vel.y = 0
					break search_y
				}
			}
		}

		if g := ecs.get(&s.grounded, e); g != nil {
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
						if world.is_solid_at(&s.terrain, {tx, ty}) {
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

// Hazard tiles append damage events; they do not subtract health. The damage
// drain is the only thing that writes to the health array, so "what killed
// me" stays answerable in one place.
hazard_damage :: proc(s: ^State, dt: f32) {
	for _, i in s.health.dense {
		e := s.health.owners[i]

		col := ecs.get(&s.collider, e)
		pos := ecs.get(&s.position, e)
		if col == nil || pos == nil {
			continue
		}

		box := aabb_of(pos^, col^)
		lo, hi := tile_span(box)
		total: f32
		for ty in lo.y ..= hi.y {
			for tx in lo.x ..= hi.x {
				hazard := world.tile_definitions[world.tile_at(&s.terrain, {tx, ty})].hazard
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
	if len(s.item.dense) == 0 || len(s.inventory.dense) == 0 {
		return
	}

	for _, ci in s.inventory.dense {
		collector := s.inventory.owners[ci]
		c_pos := ecs.get(&s.position, collector)
		c_col := ecs.get(&s.collider, collector)
		if c_pos == nil || c_col == nil {
			continue
		}
		c_box := aabb_of(c_pos^, c_col^)

		for slot, ii in s.item.dense {
			item_entity := s.item.owners[ii]
			i_pos := ecs.get(&s.position, item_entity)
			i_col := ecs.get(&s.collider, item_entity)
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
