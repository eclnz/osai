package tests

import "../src/ecs"
import "../src/sim"
import "../src/world"
import "core:os"
import "core:testing"

// A flat test world: solid stone from tile row 10 down, air above.
@(private)
flat_state :: proc(s: ^sim.State, seed: u64 = 99) {
	sim.state_init(s, seed)
	for cy in -1 ..= 1 {
		for cx in -1 ..= 1 {
			cc := world.Chunk_Coord{i32(cx), i32(cy)}
			chunk := world.generate_chunk(seed, cc)
			origin := world.chunk_origin_tile(cc)
			for ly in 0 ..< i32(world.CHUNK_TILES) {
				for lx in 0 ..< i32(world.CHUNK_TILES) {
					ty := origin.y + ly
					chunk.tiles[int(ly) * world.CHUNK_TILES + int(lx)] = ty >= 10 ? .Stone : .Empty
				}
			}
			world.insert_chunk(&s.terrain, chunk)
			s.residency.resident[cc] = true
			s.residency.populated[cc] = true
		}
	}
}

@(test)
gravity_and_terrain_collision_land_an_entity :: proc(t: ^testing.T) {
	s: sim.State
	flat_state(&s)
	defer sim.state_destroy(&s)

	e := sim.spawn_player(&s, {40, 0})
	for _ in 0 ..< 120 {
		sim.fixed_step(&s)
	}

	pos := ecs.get(&s.spatial.position, e)
	col := ecs.get(&s.spatial.collider, e)
	grounded := ecs.get(&s.spatial.grounded, e)

	// Feet rest exactly on the top of row 10, and stay there.
	testing.expect_value(t, pos.y + col.size.y, f32(10 * world.TILE_SIZE))
	testing.expect(t, grounded.on_ground)
	testing.expect_value(t, ecs.get(&s.spatial.velocity, e).y, 0)
}

@(test)
intent_drives_movement_and_jumping :: proc(t: ^testing.T) {
	s: sim.State
	flat_state(&s)
	defer sim.state_destroy(&s)

	e := sim.spawn_player(&s, {40, 100})
	for _ in 0 ..< 60 {sim.fixed_step(&s)} // settle on the ground

	start_x := ecs.get(&s.spatial.position, e).x
	intent := ecs.get(&s.control.intent, e)
	intent.horizontal = 1
	intent.jump_requested = true

	sim.fixed_step(&s)
	// The movement system consumes the jump request itself, so a held key is
	// one jump rather than one per catch-up step.
	testing.expect(t, !ecs.get(&s.control.intent, e).jump_requested)
	testing.expect(t, ecs.get(&s.spatial.velocity, e).y < 0, "jump should give upward velocity")

	for _ in 0 ..< 30 {
		ecs.get(&s.control.intent, e).horizontal = 1
		sim.fixed_step(&s)
	}
	testing.expect(t, ecs.get(&s.spatial.position, e).x > start_x)
}

@(test)
absence_of_health_means_invulnerable :: proc(t: ^testing.T) {
	s: sim.State
	flat_state(&s)
	defer sim.state_destroy(&s)

	player := sim.spawn_player(&s, {40, 0})
	coin := sim.spawn_coin(&s, {200, 0}) // no health component

	append(&s.events.damage, sim.Damage_Event{target = player, amount = 10})
	append(&s.events.damage, sim.Damage_Event{target = coin, amount = 10})
	sim.drain_damage(&s)

	testing.expect_value(t, ecs.get(&s.status.health, player).current, 90)
	// Not a special case, not a flag: the coin is simply not in the array.
	testing.expect(t, !ecs.has(&s.status.health, coin))
	testing.expect(t, ecs.entity_is_alive(&s.entities, coin))
}

@(test)
hazard_tiles_damage_through_the_queue :: proc(t: ^testing.T) {
	s: sim.State
	flat_state(&s)
	defer sim.state_destroy(&s)

	for tx in 0 ..< i32(8) {
		world.set_tile(&s.terrain, {tx, 9}, .Lava)
	}

	e := sim.spawn_player(&s, {40, 0})
	before := ecs.get(&s.status.health, e).current
	for _ in 0 ..< 120 {
		sim.fixed_step(&s)
	}
	after := ecs.get(&s.status.health, e).current
	testing.expect(t, after < before, "standing in lava should hurt")
}

@(test)
pickups_move_through_the_queue_and_destroy_the_item :: proc(t: ^testing.T) {
	s: sim.State
	flat_state(&s)
	defer sim.state_destroy(&s)

	player := sim.spawn_player(&s, {40, 100})
	coin := sim.spawn_coin(&s, {44, 104})

	sim.fixed_step(&s)

	inv := ecs.get(&s.items.inventory, player)
	testing.expect_value(t, inv.slots[0].item, sim.Item_Id.Coin)
	testing.expect_value(t, inv.slots[0].count, u16(1))
	testing.expect(t, !ecs.entity_is_alive(&s.entities, coin), "collected item is destroyed")
	testing.expect(t, !ecs.has(&s.spatial.position, coin), "and leaves no component behind")
}

@(test)
death_destroys_the_entity_and_frees_the_slot :: proc(t: ^testing.T) {
	s: sim.State
	flat_state(&s)
	defer sim.state_destroy(&s)

	e := sim.spawn_walker(&s, {40, 100})
	append(&s.events.damage, sim.Damage_Event{target = e, amount = 1000})

	sim.fixed_step(&s)

	testing.expect(t, !ecs.entity_is_alive(&s.entities, e))
	testing.expect(t, !ecs.has(&s.spatial.position, e))
	testing.expect(t, !ecs.has(&s.status.health, e))
	testing.expect(t, !ecs.has(&s.presentation.animation, e))
}

@(test)
inventory_stacks_within_limits :: proc(t: ^testing.T) {
	inv: sim.Inventory
	testing.expect_value(t, sim.inventory_add(&inv, .Rock, 20), u16(20))
	testing.expect_value(t, inv.slots[0].count, u16(20))

	// 32 is the rock stack limit: 20 tops out the first slot, the rest opens
	// a second.
	testing.expect_value(t, sim.inventory_add(&inv, .Rock, 20), u16(20))
	testing.expect_value(t, inv.slots[0].count, u16(32))
	testing.expect_value(t, inv.slots[1].count, u16(8))

	// Fill every slot, then check a full inventory refuses rather than
	// silently dropping.
	for _ in 0 ..< sim.INVENTORY_SLOTS {
		sim.inventory_add(&inv, .Rock, 32)
	}
	testing.expect_value(t, sim.inventory_add(&inv, .Rock, 5), u16(0))
}
