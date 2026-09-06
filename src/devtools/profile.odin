package devtools

import "../ecs"
import "../sim"

// A per-system breakdown of the fixed step.
//
// This mirrors `sim.fixed_step` and the per-tick passes the headless runner
// drives around it, with a stopwatch around each part. Mirroring means it can
// drift from step.odin - that is the price of keeping profiling out of the
// simulation, and it is the right trade: a measuring tool that goes stale is
// visible, a simulation that carries timers everywhere is not.
//
// The order below must match step.odin exactly, or the state evolves
// differently and the numbers describe a game you are not shipping.
Profile :: struct {
	streaming:    Stopwatch,
	ai:           Stopwatch,
	weapon:       Stopwatch,
	movement:     Stopwatch,
	projectile:   Stopwatch,
	integration:  Stopwatch,
	terrain:      Stopwatch,
	hazard:       Stopwatch,
	broadphase:   Stopwatch,
	entity_hit:   Stopwatch,
	projectile_hit: Stopwatch,
	facing:       Stopwatch,
	drain_damage: Stopwatch,
	drain_pick:   Stopwatch,
	drain_spawn:  Stopwatch,
	consequences: Stopwatch,
	animation:    Stopwatch,
	tick:         Stopwatch,
}

Sample :: struct {
	name:    string,
	mean_us: f64,
	peak_us: f64,
}

// The player is held still: streaming must not unload the population being
// measured, and a scripted walk would make every run measure a different
// stretch of terrain.
profile :: proc(s: ^sim.State, ticks: int) -> Profile {
	p: Profile
	dt := sim.FIXED_DT

	for _ in 0 ..< ticks {
		begin(&p.tick)

		player_pos := ecs.get_or(&s.spatial.position, s.player, sim.Vec2{})
		begin(&p.streaming);sim.streaming_update(s, player_pos);end(&p.streaming)

		if intent := ecs.get(&s.control.intent, s.player); intent != nil {
			intent.horizontal = 0
			intent.jump_requested = false
		}

		begin(&p.ai);sim.ai_system(s, dt);end(&p.ai)
		begin(&p.weapon);sim.weapon_system(s, dt);end(&p.weapon)
		begin(&p.movement);sim.movement_system(s, dt);end(&p.movement)
		begin(&p.projectile);sim.projectile_system(s, dt);end(&p.projectile)
		begin(&p.integration);sim.integration_system(s, dt);end(&p.integration)

		// collision_system's three passes, timed separately
		begin(&p.terrain);sim.terrain_collision(s, dt);end(&p.terrain)
		begin(&p.hazard);sim.hazard_damage(s, dt);end(&p.hazard)
		begin(&p.broadphase);bp := sim.broadphase_build(s);end(&p.broadphase)
		begin(&p.entity_hit);sim.entity_collision(s, &bp);end(&p.entity_hit)
		begin(&p.projectile_hit);sim.projectile_collision(s, &bp);end(&p.projectile_hit)

		begin(&p.facing);sim.facing_system(s, dt);end(&p.facing)
		begin(&p.drain_damage);sim.drain_damage(s);end(&p.drain_damage)
		begin(&p.drain_pick);sim.drain_pickups(s);end(&p.drain_pick)
		begin(&p.drain_spawn);sim.drain_spawns(s);end(&p.drain_spawn)
		begin(&p.consequences);sim.consequences_system(s, dt);end(&p.consequences)
		s.tick += 1

		begin(&p.animation);sim.animation_system(s, dt);end(&p.animation)

		clear(&s.events.sounds)
		free_all(context.temp_allocator)
		end(&p.tick)
	}
	return p
}

// Flat list, so a caller can sort and print without knowing the field names.
samples :: proc(p: Profile, allocator := context.allocator) -> [dynamic]Sample {
	out := make([dynamic]Sample, allocator)
	add :: proc(out: ^[dynamic]Sample, name: string, sw: Stopwatch) {
		append(out, Sample{name = name, mean_us = mean_us(sw), peak_us = peak_us(sw)})
	}
	add(&out, "streaming", p.streaming)
	add(&out, "ai", p.ai)
	add(&out, "weapon", p.weapon)
	add(&out, "movement", p.movement)
	add(&out, "projectile", p.projectile)
	add(&out, "integration", p.integration)
	add(&out, "terrain_collision", p.terrain)
	add(&out, "hazard_damage", p.hazard)
	add(&out, "broadphase", p.broadphase)
	add(&out, "entity_collision", p.entity_hit)
	add(&out, "projectile_collision", p.projectile_hit)
	add(&out, "facing", p.facing)
	add(&out, "drain_damage", p.drain_damage)
	add(&out, "drain_pickups", p.drain_pick)
	add(&out, "drain_spawns", p.drain_spawn)
	add(&out, "consequences", p.consequences)
	add(&out, "animation", p.animation)
	return out
}
