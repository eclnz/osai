package sim

import "../ecs"
import "../serial"
import "../world"

// Presence means "moves under its own power"; the field says which row of
// `entity_definitions` supplies the numbers, rather than copying 24 bytes of
// them onto every walker.
Movement :: struct {
	def: Entity_Kind,
}

Intent :: struct {
	horizontal:     f32, // -1 .. 1
	jump_requested: bool,
	// Latched: whoever writes intent sets it, the system acting on it clears
	// it, so one press is one shot however many steps the frame runs.
	fire_requested: bool,
	// Held, not latched - digging is continuous, so nothing consumes this.
	dig_requested:  bool,
	// World units, not screen: nothing in `sim` knows a screen exists.
	aim:            Vec2,
}

// Progress lives on the digger, not the tile: two entities working the same
// block each get their own, an unloading chunk has nothing to clear, and a
// tile stays one byte.
Digger :: struct {
	// World units, from the entity's centre.
	reach:    f32,
	// Multiplies progress against `hardness`; a better tool is a bigger number.
	speed:    f32,
	target:   world.Tile_Coord,
	progress: f32,
}

AI_Behaviour :: enum u8 {
	Idle,
	Patrol,
}

AI_State :: struct {
	behaviour: AI_Behaviour,
	// What the cached probe below answered.
	turn:      bool,
	facing:    f32,
	timer:     f32,

	// Cache key for the wall-and-ledge probe, which a walker re-asks for the
	// ~23 ticks it spends crossing one tile. The answer depends only on the
	// two probed tiles and on the terrain, so both are in the key. Both
	// coordinates are needed: taken at different heights, they cross tile
	// boundaries at different times.
	//
	// Zero means never probed, which is why `Terrain.edits` starts at one.
	probe_edits: u32,
	probe_ahead: world.Tile_Coord,
	probe_floor: world.Tile_Coord,
}


Control :: struct {
	intent:   ecs.Sparse_Set(Intent),
	movement: ecs.Sparse_Set(Movement),
	ai:       ecs.Sparse_Set(AI_State),
	digger:   ecs.Sparse_Set(Digger),
}

Control_Snapshot :: struct {
	intent:   Intent,
	movement: Movement,
	ai:       AI_State,
	digger:   Digger,
}

control_destroy :: proc(c: ^Control) {
	ecs.set_destroy(&c.intent)
	ecs.set_destroy(&c.movement)
	ecs.set_destroy(&c.ai)
	ecs.set_destroy(&c.digger)
}

control_detach :: proc(c: ^Control, e: ecs.Entity) {
	ecs.remove(&c.intent, e)
	ecs.remove(&c.movement, e)
	ecs.remove(&c.ai, e)
	ecs.remove(&c.digger, e)
}

control_save :: proc(w: ^serial.Writer, c: ^Control) {
	serial.put_set(w, &c.intent)
	serial.put_set(w, &c.movement)
	serial.put_set(w, &c.ai)
	serial.put_set(w, &c.digger)
}

control_load :: proc(r: ^serial.Reader, c: ^Control) -> bool {
	serial.take_set(r, &c.intent) or_return
	serial.take_set(r, &c.movement) or_return
	serial.take_set(r, &c.ai) or_return
	serial.take_set(r, &c.digger) or_return
	return true
}

control_capture :: proc(c: ^Control, e: ecs.Entity, snap: ^Control_Snapshot) -> Component_Flags {
	present: Component_Flags
	if v := ecs.get(&c.intent, e); v != nil {snap.intent = v^;present += {.Intent}}
	if v := ecs.get(&c.movement, e); v != nil {snap.movement = v^;present += {.Movement}}
	if v := ecs.get(&c.ai, e); v != nil {snap.ai = v^;present += {.AI}}
	if v := ecs.get(&c.digger, e); v != nil {snap.digger = v^;present += {.Digger}}
	return present
}

control_restore :: proc(c: ^Control, e: ecs.Entity, snap: Control_Snapshot, present: Component_Flags) {
	if .Intent in present {ecs.add(&c.intent, e, snap.intent)}
	if .Movement in present {ecs.add(&c.movement, e, snap.movement)}
	if .AI in present {ecs.add(&c.ai, e, snap.ai)}
	if .Digger in present {ecs.add(&c.digger, e, snap.digger)}
}
