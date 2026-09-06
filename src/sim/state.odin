package sim

import "../ecs"
import "../world"

// Component arrays, a terrain and some queues. There is no `Entity` object
// anywhere, and no system owns any of this: they are all handed the same
// `^State`.

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

	// Scratch, not state: rebuilt every step, never saved. Temp-allocated, so
	// it must not be read once the frame's temp arena is freed.
	broadphase: Broadphase,

	seed:   u64,
	tick:   u64,
	player: ecs.Entity,

	// Entities a pass decided to destroy while still iterating the array they
	// live in - destroying inline swap-and-pops it underneath the loop.
	// Always empty between passes, so it is scratch and is not saved.
	//
	// Deliberately not a destroy queue drained once at the end of the step.
	// The drains destroy immediately and use liveness as a claim: two
	// collectors overlapping one coin both queue a pickup, and it is the
	// first one's destroy that makes the second's handle stale. Defer that
	// and both collect the same coin.
	pending_destroy: [dynamic]ecs.Entity,
}

// Safe to call while iterating any component array.
destroy_pending :: proc(s: ^State, e: ecs.Entity) {
	append(&s.pending_destroy, e)
}

// Called by the pass that filled the buffer, before it returns.
flush_pending_destroys :: proc(s: ^State) {
	for e in s.pending_destroy {
		entity_destroy(s, e)
	}
	clear(&s.pending_destroy)
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
	delete(s.pending_destroy)
	world.terrain_destroy(&s.terrain)
	s^ = {}
}

// One call per group, so adding a component means editing that group's file
// and nothing else. The compiler will still not remind you.
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
