package sim

import "../ecs"
import "../world"

// The simulation is a bag of component arrays, a terrain, and some queues.
// There is no `Entity` object anywhere, and no system owns any of this - they
// are all handed the same `^State` and read and write the arrays they care
// about.

State :: struct {
	entities: ecs.Entity_Store,
	identity: Identity,
	spatial: Spatial,
	control: Control,
	status: Status,
	presentation: Presentation,
	items: Items,
	combat: Combat,

	terrain: world.Terrain,
	events:  Event_Queues,
	residency: Residency,

	seed:   u64,
	tick:   u64,
	player: ecs.Entity,
}

state_init :: proc(s: ^State, seed: u64) {
	s.seed = seed
	s.player = ecs.NIL
	world.terrain_init(&s.terrain, seed)
	residency_init(&s.residency)
}

state_destroy :: proc(s: ^State) {
	ecs.entity_store_destroy(&s.entities)

	identity_destroy(&s.identity)
	spatial_destroy(&s.spatial)
	control_destroy(&s.control)
	status_destroy(&s.status)
	presentation_destroy(&s.presentation)
	items_destroy(&s.items)
	combat_destroy(&s.combat)

	residency_destroy(&s.residency)

	events_destroy(&s.events)
	world.terrain_destroy(&s.terrain)
	s^ = {}
}

// One call per group. Each group file owns the list of its own arrays, so
// adding a component means editing that group and nothing else. The compiler
// still will not remind you - it just has one fewer place to be forgotten in.
detach_all_components :: proc(s: ^State, e: ecs.Entity) {
	identity_detach(&s.identity, e)
	spatial_detach(&s.spatial, e)
	control_detach(&s.control, e)
	status_detach(&s.status, e)
	presentation_detach(&s.presentation, e)
	items_detach(&s.items, e)
	combat_detach(&s.combat, e)
}

entity_destroy :: proc(s: ^State, e: ecs.Entity) {
	if !ecs.entity_is_alive(&s.entities, e) {
		return
	}
	detach_all_components(s, e)
	ecs.entity_destroy(&s.entities, e)
	if s.player == e {
		s.player = ecs.NIL
	}
}
