package sim

import "../ecs"
import "../world"

// Systems never call each other. They communicate through frame-scoped event
// queues: appended by many systems, drained by exactly one, then cleared.
//
// The rule that makes this work is ordering: a queue is drained *after*
// everything that can append to it, and the drain order is fixed in step.odin.

Damage_Event :: struct {
	target: ecs.Entity,
	amount: f32,
	source: Damage_Source,
}

Damage_Source :: enum u8 {
	Unknown,
	Hazard_Tile,
	Contact,
}

Pickup_Event :: struct {
	collector: ecs.Entity,
	// The entity carrying the item in the world; destroyed by the drain.
	item_entity: ecs.Entity,
	item:        Item_Id,
	count:       u16,
}

Spawn_Request :: world.Spawn_Request

Sound_Id :: enum u8 {
	None,
	Jump,
	Hurt,
	Pickup,
	Death,
}

Sound_Request :: struct {
	sound:    Sound_Id,
	position: Vec2,
}

Event_Queues :: struct {
	damage:  [dynamic]Damage_Event,
	pickups: [dynamic]Pickup_Event,
	spawns:  [dynamic]Spawn_Request,
	sounds:  [dynamic]Sound_Request,
}

events_destroy :: proc(q: ^Event_Queues) {
	delete(q.damage)
	delete(q.pickups)
	delete(q.spawns)
	delete(q.sounds)
	q^ = {}
}

// Note that there is no clear-everything procedure: each drain in drains.odin
// clears the one queue it owns, so an append made *after* that drain survives
// to the next fixed step instead of being swept away. Sounds are drained by
// the presentation layer once per frame rather than per fixed step.
