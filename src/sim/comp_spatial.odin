package sim

import "../ecs"
import "../serial"

// Sticky: follows actual movement, so an entity that stops keeps facing the
// way it was going.
Facing :: distinct f32 // -1 left, +1 right

Collider :: struct {
	size: Vec2,
}

Grounded :: struct {
	on_ground: bool,
}

// How terrain collision answers. Absent means stop dead against the tile
// face, which is why nothing that walks carries one.
Bounce :: struct {
	restitution: f32, // fraction of speed kept across the contact
	friction:    f32, // fraction of the tangential speed shed per contact
	// Rolling friction along the surface, in world units per second squared.
	// Per second and not per contact: resting on a floor is a contact resolved
	// every tick, so per-contact would tie rolling to the tick rate.
	rolling:     f32,
	// Below this speed, settle instead of reflecting - otherwise the entity
	// jitters on the floor forever.
	min_speed:   f32,
}

Spatial :: struct {
	position:          ecs.Sparse_Set(Vec2),
	previous_position: ecs.Sparse_Set(Vec2),
	velocity:          ecs.Sparse_Set(Vec2),
	collider:          ecs.Sparse_Set(Collider),
	grounded:          ecs.Sparse_Set(Grounded),
	facing:            ecs.Sparse_Set(Facing),
	bounce:            ecs.Sparse_Set(Bounce),
}

Spatial_Snapshot :: struct {
	position:          Vec2,
	previous_position: Vec2,
	velocity:          Vec2,
	collider:          Collider,
	grounded:          Grounded,
	facing:            Facing,
	bounce:            Bounce,
}

spatial_destroy :: proc(sp: ^Spatial) {
	ecs.set_destroy(&sp.position)
	ecs.set_destroy(&sp.previous_position)
	ecs.set_destroy(&sp.velocity)
	ecs.set_destroy(&sp.collider)
	ecs.set_destroy(&sp.grounded)
	ecs.set_destroy(&sp.facing)
	ecs.set_destroy(&sp.bounce)
}

spatial_detach :: proc(sp: ^Spatial, e: ecs.Entity) {
	ecs.remove(&sp.position, e)
	ecs.remove(&sp.previous_position, e)
	ecs.remove(&sp.velocity, e)
	ecs.remove(&sp.collider, e)
	ecs.remove(&sp.grounded, e)
	ecs.remove(&sp.facing, e)
	ecs.remove(&sp.bounce, e)
}

spatial_save :: proc(w: ^serial.Writer, sp: ^Spatial) {
	serial.put_set(w, &sp.position)
	serial.put_set(w, &sp.previous_position)
	serial.put_set(w, &sp.velocity)
	serial.put_set(w, &sp.collider)
	serial.put_set(w, &sp.grounded)
	serial.put_set(w, &sp.facing)
	serial.put_set(w, &sp.bounce)
}

spatial_load :: proc(r: ^serial.Reader, sp: ^Spatial) -> bool {
	serial.take_set(r, &sp.position) or_return
	serial.take_set(r, &sp.previous_position) or_return
	serial.take_set(r, &sp.velocity) or_return
	serial.take_set(r, &sp.collider) or_return
	serial.take_set(r, &sp.grounded) or_return
	serial.take_set(r, &sp.facing) or_return
	serial.take_set(r, &sp.bounce) or_return
	return true
}

// Returns flags for the components that were present, for the caller to fold
// into the whole entity's set.
spatial_capture :: proc(sp: ^Spatial, e: ecs.Entity, snap: ^Spatial_Snapshot) -> Component_Flags {
	present: Component_Flags
	if v := ecs.get(&sp.position, e); v != nil {snap.position = v^;present += {.Position}}
	if v := ecs.get(&sp.previous_position, e); v != nil {snap.previous_position = v^;present += {.Previous_Position}}
	if v := ecs.get(&sp.velocity, e); v != nil {snap.velocity = v^;present += {.Velocity}}
	if v := ecs.get(&sp.collider, e); v != nil {snap.collider = v^;present += {.Collider}}
	if v := ecs.get(&sp.grounded, e); v != nil {snap.grounded = v^;present += {.Grounded}}
	if v := ecs.get(&sp.facing, e); v != nil {snap.facing = v^;present += {.Facing}}
	if v := ecs.get(&sp.bounce, e); v != nil {snap.bounce = v^;present += {.Bounce}}
	return present
}

spatial_restore :: proc(sp: ^Spatial, e: ecs.Entity, snap: Spatial_Snapshot, present: Component_Flags) {
	if .Position in present {ecs.add(&sp.position, e, snap.position)}
	if .Previous_Position in present {ecs.add(&sp.previous_position, e, snap.previous_position)}
	if .Velocity in present {ecs.add(&sp.velocity, e, snap.velocity)}
	if .Collider in present {ecs.add(&sp.collider, e, snap.collider)}
	if .Grounded in present {ecs.add(&sp.grounded, e, snap.grounded)}
	if .Facing in present {ecs.add(&sp.facing, e, snap.facing)}
	if .Bounce in present {ecs.add(&sp.bounce, e, snap.bounce)}
}
