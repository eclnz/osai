package sim

import "../ecs"
import "../world"
import "../serial"

Damage_Event :: struct {
	target: ecs.Entity,
	amount: f32,
	source: Damage_Source,
}

Damage_Source :: enum u8 {
	Unknown,
	Hazard_Tile,
	Contact,
	Projectile,
}

Hit_Event :: struct {
	projectile: ecs.Entity,
	target:     ecs.Entity,
	damage:     f32,
	position:   Vec2,
}

Pickup_Event :: struct {
	collector: ecs.Entity,
	item_entity: ecs.Entity,
	item:        Item_Id,
	count:       u16,
}

Spawn_Request :: world.Spawn_Request

Sound_Id :: enum u8 {
	None,
	Jump,
	Fire,
	Break,
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
	hits:    [dynamic]Hit_Event,
	pickups: [dynamic]Pickup_Event,
	spawns:  [dynamic]Spawn_Request,
	sounds:  [dynamic]Sound_Request,
}

events_destroy :: proc(q: ^Event_Queues) {
	delete(q.damage)
	delete(q.hits)
	delete(q.pickups)
	delete(q.spawns)
	delete(q.sounds)
	q^ = {}
}

// Note that there is no clear-everything procedure: each drain in sys_drains.odin
// clears the one queue it owns, so an append made *after* that drain survives
// to the next fixed step instead of being swept away. Sounds are drained by
// the presentation layer once per frame rather than per fixed step.

// Pending work has to survive a save, for the same reason it survives a step.
// It is tempting to skip this on the grounds that the queues happen to be
// empty whenever the game is saved today - but that is only true because
// collision is currently the sole producer of damage. A potion, a burn or a
// poison tick would run after `drain_damage` and leave damage pending across
// the step boundary, exactly as the partial drain in `drain_spawns` already
// anticipates for loot.
//
// `sounds` is the exception, and is deliberately absent: it is presentation
// output, cleared once per rendered frame rather than per fixed step, and
// replaying it on load would only fire a burst of stale audio.
//
// The entity handles inside these events stay valid across the round trip
// because generations are restored with the entity store.
events_save :: proc(w: ^serial.Writer, q: ^Event_Queues) {
	serial.put_array(w, q.damage[:])
	serial.put_array(w, q.hits[:])
	serial.put_array(w, q.pickups[:])
	serial.put_array(w, q.spawns[:])
}

events_load :: proc(r: ^serial.Reader, q: ^Event_Queues) -> bool {
	serial.take_array(r, &q.damage) or_return
	serial.take_array(r, &q.hits) or_return
	serial.take_array(r, &q.pickups) or_return
	serial.take_array(r, &q.spawns) or_return
	return true
}
