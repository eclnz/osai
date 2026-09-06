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

// There is deliberately no clear-everything procedure: each drain clears the
// one queue it owns, so an append made after that drain survives to the next
// fixed step instead of being swept away.

// Pending work survives a save for the same reason it survives a step. The
// queues happen to be empty at every save today, but only because collision is
// the sole producer of damage; a burn or a poison tick would leave damage
// pending across the boundary.
//
// `sounds` is deliberately absent: it is presentation output, and replaying it
// on load would fire a burst of stale audio.
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
