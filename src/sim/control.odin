package sim

import "../ecs"
import "../serial"

// Presence declares that this entity moves under its own power; the field
// says which row of `entity_definitions` supplies the numbers. A coin has no
// Movement component at all, so `movement_system` never sees it - the absence
// is the declaration, exactly as before. What is gone is the *copy*: the 24
// bytes of identical parameters that used to sit on every walker.
Movement :: struct {
	def: Entity_Kind,
}

Intent :: struct {
	horizontal:     f32, // -1 .. 1
	jump_requested: bool,
	// Latched like `jump_requested`, and consumed by `weapon_system` in the
	// same way: whoever writes intent sets it, whoever acts on it clears it.
	fire_requested: bool,
}

AI_Behaviour :: enum u8 {
	Idle,
	Patrol,
}

AI_State :: struct {
	behaviour: AI_Behaviour,
	facing:    f32,
	timer:     f32,
}


Control :: struct {
	intent:   ecs.Sparse_Set(Intent),
	movement: ecs.Sparse_Set(Movement),
	ai:       ecs.Sparse_Set(AI_State),
}

Control_Snapshot :: struct {
	intent:   Intent,
	movement: Movement,
	ai:       AI_State,
}

control_destroy :: proc(c: ^Control) {
	ecs.set_destroy(&c.intent)
	ecs.set_destroy(&c.movement)
	ecs.set_destroy(&c.ai)
}

control_detach :: proc(c: ^Control, e: ecs.Entity) {
	ecs.remove(&c.intent, e)
	ecs.remove(&c.movement, e)
	ecs.remove(&c.ai, e)
}

control_save :: proc(w: ^serial.Writer, c: ^Control) {
	serial.put_set(w, &c.intent)
	serial.put_set(w, &c.movement)
	serial.put_set(w, &c.ai)
}

control_load :: proc(r: ^serial.Reader, c: ^Control) -> bool {
	serial.take_set(r, &c.intent) or_return
	serial.take_set(r, &c.movement) or_return
	serial.take_set(r, &c.ai) or_return
	return true
}

control_capture :: proc(c: ^Control, e: ecs.Entity, snap: ^Control_Snapshot) -> Component_Flags {
	present: Component_Flags
	if v := ecs.get(&c.intent, e); v != nil {snap.intent = v^;present += {.Intent}}
	if v := ecs.get(&c.movement, e); v != nil {snap.movement = v^;present += {.Movement}}
	if v := ecs.get(&c.ai, e); v != nil {snap.ai = v^;present += {.AI}}
	return present
}

control_restore :: proc(c: ^Control, e: ecs.Entity, snap: Control_Snapshot, present: Component_Flags) {
	if .Intent in present {ecs.add(&c.intent, e, snap.intent)}
	if .Movement in present {ecs.add(&c.movement, e, snap.movement)}
	if .AI in present {ecs.add(&c.ai, e, snap.ai)}
}
