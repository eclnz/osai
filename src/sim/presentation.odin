package sim

import "../ecs"
import "../serial"

// What an entity looks like: which texture, which animation, and how far
// forward it sorts.
//
// Written by the simulation, read only by the renderer. That direction is
// enforced by the package graph - `sim` does not import `render` - so nothing
// here can reach a pixel. Note what is deliberately absent: no source
// rectangle, no sheet dimensions, no flip flag. Those are the renderer's, and
// `Facing` is spatial, not presentational.
//
// `Animation_Id` and `Animation_State` are declared in animation.odin, with
// the definition table and the system that drives them.

Texture_Id :: enum u8 {
	None,
	Player,
	Creature,
	Item,
}

Appearance :: struct {
	texture: Texture_Id,
	tint:    [4]u8,
}

Layer :: struct {
	depth: i16,
}

Presentation :: struct {
	appearance: ecs.Sparse_Set(Appearance),
	animation:  ecs.Sparse_Set(Animation_State),
	layer:      ecs.Sparse_Set(Layer),
}

Presentation_Snapshot :: struct {
	appearance: Appearance,
	animation:  Animation_State,
	layer:      Layer,
}

presentation_destroy :: proc(p: ^Presentation) {
	ecs.set_destroy(&p.appearance)
	ecs.set_destroy(&p.animation)
	ecs.set_destroy(&p.layer)
}

presentation_detach :: proc(p: ^Presentation, e: ecs.Entity) {
	ecs.remove(&p.appearance, e)
	ecs.remove(&p.animation, e)
	ecs.remove(&p.layer, e)
}

// Write order here is the read order in `presentation_load`.
presentation_save :: proc(w: ^serial.Writer, p: ^Presentation) {
	serial.put_set(w, &p.appearance)
	serial.put_set(w, &p.animation)
	serial.put_set(w, &p.layer)
}

presentation_load :: proc(r: ^serial.Reader, p: ^Presentation) -> bool {
	serial.take_set(r, &p.appearance) or_return
	serial.take_set(r, &p.animation) or_return
	serial.take_set(r, &p.layer) or_return
	return true
}

presentation_capture :: proc(
	p: ^Presentation,
	e: ecs.Entity,
	snap: ^Presentation_Snapshot,
) -> Component_Flags {
	present: Component_Flags
	if v := ecs.get(&p.appearance, e); v != nil {snap.appearance = v^;present += {.Appearance}}
	if v := ecs.get(&p.animation, e); v != nil {snap.animation = v^;present += {.Animation}}
	if v := ecs.get(&p.layer, e); v != nil {snap.layer = v^;present += {.Layer}}
	return present
}

presentation_restore :: proc(
	p: ^Presentation,
	e: ecs.Entity,
	snap: Presentation_Snapshot,
	present: Component_Flags,
) {
	if .Appearance in present {ecs.add(&p.appearance, e, snap.appearance)}
	if .Animation in present {ecs.add(&p.animation, e, snap.animation)}
	if .Layer in present {ecs.add(&p.layer, e, snap.layer)}
}
