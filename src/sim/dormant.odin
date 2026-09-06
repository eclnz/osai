package sim

import "../ecs"

// A whole entity as plain data, for an entity that is not currently resident.
//
// This is a *format*, not a system. `residency.dormant` stores these, keyed by
// the chunk they belong to, and save.odin persists them verbatim - which works
// only because every field is POD, so the blob is one memcpy from being a file
// record. A component holding a pointer would compile fine here and produce a
// corrupt save.
//
// streaming.odin decides when an entity becomes dormant and when it wakes;
// this file only describes what is kept in the meantime.

Component_Flag :: enum u8 {
	Position,
	Previous_Position,
	Velocity,
	Collider,
	Grounded,
	Intent,
	Kind,
	Movement,
	AI,
	Digger,
	Health,
	Appearance,
	Animation,
	Facing,
	Bounce,
	Layer,
	Inventory,
	Item,
	Weapon,
	Projectile,
}

Component_Flags :: bit_set[Component_Flag;u32]

// A whole entity as plain data. Every field is POD, so this is one memcpy
// away from being a save file record - which is exactly what save.odin does
// with it.
Dormant_Entity :: struct {
	entity:  ecs.Entity,
	present: Component_Flags,

	// Grouped components are embedded rather than listed, so a group stays one
	// thing here too. `using` keeps `d.position` and `d.animation` resolving,
	// so call sites do not care which arrangement a component arrived in.
	using identity:     Identity_Snapshot,
	using spatial:      Spatial_Snapshot,
	using presentation: Presentation_Snapshot,

	using control:      Control_Snapshot,
	using status:         Status_Snapshot,
	using items:        Items_Snapshot,
	using combat:       Combat_Snapshot,
}

// One line per group, same as `detach_all_components`. Each group decides
// which of its own components were present and folds its flags into the set.
capture_entity :: proc(s: ^State, e: ecs.Entity) -> Dormant_Entity {
	d := Dormant_Entity {
		entity = e,
	}
	d.present = identity_capture(&s.identity, e, &d.identity)
	d.present += spatial_capture(&s.spatial, e, &d.spatial)
	d.present += control_capture(&s.control, e, &d.control)
	d.present += status_capture(&s.status, e, &d.status)
	d.present += presentation_capture(&s.presentation, e, &d.presentation)
	d.present += items_capture(&s.items, e, &d.items)
	d.present += combat_capture(&s.combat, e, &d.combat)
	return d
}

restore_entity :: proc(s: ^State, d: Dormant_Entity) {
	e := d.entity
	identity_restore(&s.identity, e, d.identity, d.present)
	spatial_restore(&s.spatial, e, d.spatial, d.present)
	control_restore(&s.control, e, d.control, d.present)
	status_restore(&s.status, e, d.status, d.present)
	presentation_restore(&s.presentation, e, d.presentation, d.present)
	items_restore(&s.items, e, d.items, d.present)
	combat_restore(&s.combat, e, d.combat, d.present)
}
