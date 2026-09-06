package sim

import "../ecs"

// The format an entity is kept in while it is not resident. streaming.odin
// decides when that happens.

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

// Every field is POD, so save.odin writes this verbatim.
Dormant_Entity :: struct {
	entity:  ecs.Entity,
	present: Component_Flags,

	// `using` so call sites say `d.position`, not `d.spatial.position`.
	using identity:     Identity_Snapshot,
	using spatial:      Spatial_Snapshot,
	using presentation: Presentation_Snapshot,

	using control:      Control_Snapshot,
	using status:         Status_Snapshot,
	using items:        Items_Snapshot,
	using combat:       Combat_Snapshot,
}

// One line per group: each folds in the flags for whichever of its own
// components were present.
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
