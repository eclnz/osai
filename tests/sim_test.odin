package tests

import "../src/ecs"
import "../src/sim"
import "../src/world"
import "core:math"
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
	sim.drain_damage(&s, sim.FIXED_DT)

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

// The hazard scan is gated on a per-chunk "any hazard at all" flag, so the
// flag has to track writes in both directions. Adding hazard is a flag set;
// removing the last of it is the case that has to look at the rest of the
// chunk, and getting that wrong would leave an entity taking damage from lava
// that is no longer there - or, worse the other way, standing in lava unhurt.
@(test)
removing_the_last_hazard_tile_stops_the_damage :: proc(t: ^testing.T) {
	s: sim.State
	flat_state(&s)
	defer sim.state_destroy(&s)

	for tx in 0 ..< i32(8) {
		world.set_tile(&s.terrain, {tx, 9}, .Lava)
	}
	testing.expect(t, world.get_chunk(&s.terrain, {0, 0}).any_hazard, "lava marks the chunk")

	e := sim.spawn_player(&s, {40, 0})
	for _ in 0 ..< 60 {
		sim.fixed_step(&s)
	}
	hurt := ecs.get(&s.status.health, e).current

	for tx in 0 ..< i32(8) {
		world.set_tile(&s.terrain, {tx, 9}, .Empty)
	}
	testing.expect(
		t,
		!world.get_chunk(&s.terrain, {0, 0}).any_hazard,
		"clearing the last lava tile must clear the flag, not leave it set",
	)

	for _ in 0 ..< 60 {
		sim.fixed_step(&s)
	}
	testing.expect_value(t, ecs.get(&s.status.health, e).current, hurt)
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

@(test)
firing_follows_the_shooter_velocity :: proc(t: ^testing.T) {
	s: sim.State
	flat_state(&s)
	defer sim.state_destroy(&s)

	player := sim.spawn_player(&s, {40, 100})
	for _ in 0 ..< 60 {sim.fixed_step(&s)} // settle on the ground

	// Run right, so the player has a velocity to fire along.
	for _ in 0 ..< 30 {
		ecs.get(&s.control.intent, player).horizontal = 1
		sim.fixed_step(&s)
	}
	testing.expect(t, ecs.get(&s.spatial.velocity, player).x > 0)

	before := len(s.combat.projectile.dense)
	ecs.get(&s.control.intent, player).fire_requested = true
	sim.fixed_step(&s)

	testing.expect_value(t, len(s.combat.projectile.dense), before + 1)
	fireball := s.combat.projectile.owners[before]
	testing.expect(t, ecs.get(&s.spatial.velocity, fireball).x > 0, "fired along the shooter's velocity")

	// Cooldown: a second request in the same second is refused.
	ecs.get(&s.control.intent, player).fire_requested = true
	sim.fixed_step(&s)
	testing.expect_value(t, len(s.combat.projectile.dense), before + 1)
}

@(test)
a_fireball_falls_and_bounces :: proc(t: ^testing.T) {
	s: sim.State
	flat_state(&s)
	defer sim.state_destroy(&s)

	// Fired flat, well above the floor at tile row 10.
	e := sim.spawn_fireball(&s, {40, 40}, {60, 0}, ecs.NIL)

	// Gravity: no downward velocity to begin with, some after a step.
	sim.fixed_step(&s)
	testing.expect(t, ecs.get(&s.spatial.velocity, e).y > 0, "gravity should pull it down")

	// Bounce: it must come back up off the floor at least once.
	bounced := false
	for _ in 0 ..< 120 {
		sim.fixed_step(&s)
		if !ecs.entity_is_alive(&s.entities, e) {
			break
		}
		if ecs.get(&s.spatial.velocity, e).y < 0 {
			bounced = true
			break
		}
	}
	testing.expect(t, bounced, "hitting the floor should reverse it, not stop it")
	testing.expect(t, ecs.get(&s.spatial.velocity, e).x > 0, "and it keeps travelling")
}

@(test)
a_fireball_damages_what_it_hits_and_spares_its_owner :: proc(t: ^testing.T) {
	s: sim.State
	flat_state(&s)
	defer sim.state_destroy(&s)

	player := sim.spawn_player(&s, {40, 100})
	walker := sim.spawn_walker(&s, {120, 100})
	before := ecs.get(&s.status.health, walker).current

	// Spawned inside the player: the owner is excluded, so this must survive
	// the tick rather than hitting the entity that fired it.
	fireball := sim.spawn_fireball(&s, {46, 106}, {200, 0}, player)
	sim.fixed_step(&s)
	testing.expect(t, ecs.entity_is_alive(&s.entities, fireball), "a shot does not hit its owner")
	testing.expect_value(t, ecs.get(&s.status.health, player).current, 100)

	for _ in 0 ..< 60 {
		sim.fixed_step(&s)
		if !ecs.entity_is_alive(&s.entities, fireball) {
			break
		}
	}
	testing.expect(t, !ecs.entity_is_alive(&s.entities, fireball), "a hit spends the projectile")
	testing.expect(t, ecs.get(&s.status.health, walker).current < before, "and damages the target")
}

@(test)
a_fireball_expires_on_its_own :: proc(t: ^testing.T) {
	s: sim.State
	flat_state(&s)
	defer sim.state_destroy(&s)

	// Straight up into open sky: nothing to hit, so only the lifetime ends it.
	e := sim.spawn_fireball(&s, {40, -400}, {0, -400}, ecs.NIL)
	steps := int(math.ceil(sim.FIREBALL_LIFETIME / sim.FIXED_DT)) + 1
	for _ in 0 ..< steps {
		sim.fixed_step(&s)
	}
	testing.expect(t, !ecs.entity_is_alive(&s.entities, e))
	testing.expect(t, !ecs.has(&s.spatial.position, e), "and leaves no component behind")
}

@(test)
a_rolling_fireball_slows_to_a_stop :: proc(t: ^testing.T) {
	s: sim.State
	flat_state(&s)
	defer sim.state_destroy(&s)

	// Dropped just above the floor with a flat run, so it settles into a roll
	// within a step or two rather than bouncing across the room first.
	e := sim.spawn_fireball(&s, {40, f32(10 * world.TILE_SIZE) - 8}, {200, 0}, ecs.NIL)

	for _ in 0 ..< 10 {sim.fixed_step(&s)}
	rolling := ecs.get(&s.spatial.velocity, e).x
	testing.expect(t, rolling > 0, "it should still be moving along the ground")

	sim.fixed_step(&s)
	testing.expect(t, ecs.get(&s.spatial.velocity, e).x < rolling, "rolling should shed speed")

	// And it comes to rest rather than creeping forever.
	for _ in 0 ..< 120 {sim.fixed_step(&s)}
	testing.expect_value(t, ecs.get(&s.spatial.velocity, e).x, 0)
}

// The README claims a seed and a tick count fully describe a run. They did
// not: several passes iterated a `map`, and Odin seeds a map's hash from the
// address its data was allocated at, so iteration order - and therefore the
// order chunks load, the order entity slots are handed out, and the order the
// dense arrays end up in - varied between runs of the same binary.
//
// Both states are kept alive at once, which is the point: run one and then the
// other and the second tends to be handed the address the first just freed,
// giving it the same map seed and hiding the bug. Held together they get
// different addresses, which is the condition that used to make them diverge.
@(test)
a_seed_and_a_tick_count_fully_describe_a_run :: proc(t: ^testing.T) {
	SEED :: u64(20250906)
	TICKS :: 900

	begin :: proc(s: ^sim.State) {
		sim.state_init(s, SEED)
		surface := world.surface_height(SEED, 0)
		spawn_y := f32(surface - 3) * world.TILE_SIZE
		sim.streaming_update(s, {0, spawn_y})
		sim.spawn_player(s, {0, spawn_y})
		sim.streaming_update(s, {0, spawn_y})
	}

	// Walking is what makes this a test: it drags the residency window across
	// chunk boundaries, so chunks load and unload and entities stream in and
	// out.
	step_all :: proc(s: ^sim.State) {
		for i in 0 ..< TICKS {
			pos := ecs.get_or(&s.spatial.position, s.player, sim.Vec2{})
			sim.streaming_update(s, pos)
			if intent := ecs.get(&s.control.intent, s.player); intent != nil {
				intent.horizontal = 1
				intent.jump_requested = i % 60 == 0
			}
			sim.fixed_step(s)
			free_all(context.temp_allocator)
		}
	}

	// Summed, not chained, so this compares where the entities are rather than
	// what order the arrays happen to hold them in.
	digest_of :: proc(s: ^sim.State) -> (digest: u64) {
		for p, i in s.spatial.position.dense {
			e := s.spatial.position.owners[i]
			h := u64(e.index) * 0x9e3779b97f4a7c15
			h ~= u64(transmute(u32)p.x) * 0xbf58476d1ce4e5b9
			h ~= u64(transmute(u32)p.y) * 0x94d049bb133111eb
			digest += h
		}
		return
	}

	a, b: sim.State
	begin(&a)
	begin(&b)
	defer sim.state_destroy(&a)
	defer sim.state_destroy(&b)

	step_all(&a)
	step_all(&b)

	testing.expect_value(t, digest_of(&b), digest_of(&a))
	testing.expect_value(t, b.entities.live_count, a.entities.live_count)
	testing.expect(t, a.entities.live_count > 1, "the run should have streamed entities in")
}
