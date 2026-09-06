package sim

import "../ecs"
import "../serial"
import "../world"

// What an entity is, as a row reference rather than a name.
//
// The stats that every walker shares - move speed, collider size, max health -
// are one table row, not a copy on each entity. `kind` is the one byte that
// says which row. This follows the convention already used three times over:
// `animation_definitions`, `item_definitions`, `tile_definitions`.
//
// This does not put identity back into the simulation. No system branches on
// kind; they index a table with it, exactly as the animation system indexes
// `animation_definitions[anim.current]`. Nothing asks "is this a player".
//
// Composition is untouched by this. Components that used to carry shared
// values still exist and still declare by presence - `Movement` is on the
// things that move and absent from a coin, as before. What changed is that it
// now holds a one-byte reference to a row instead of a private copy of it.

// Reusing world's spawn kind rather than declaring a parallel enum: it is
// already the shared vocabulary for "which sort of thing", and it means
// `spawn` can index the table straight from a Spawn_Request.
Entity_Kind :: world.Spawn_Kind

Movement_Params :: struct {
	move_speed:     f32,
	jump_speed:     f32,
	gravity:        f32,
	max_fall_speed: f32,
	// Ground friction as a fraction of speed shed per second.
	ground_damping: f32,
	air_control:    f32,
}

Entity_Definition :: struct {
	max_health: f32,
	movement:   Movement_Params,
	collider:   Vec2,
	texture:    Texture_Id,
	tint:       [4]u8,
	depth:      i16,
}

// Indexed by kind, one entry per kind.
//
// `@(rodata)` rather than a plain global: these tables are the game, not the
// state - never saved, never written at runtime - and this puts them in
// read-only memory to say so. It does not reject a write at compile time; what
// it buys is that an accidental one faults immediately instead of quietly
// changing the game, and that the optimiser knows nothing can alias and
// change a row underneath it.
//
// The table stays addressable, which matters: `movement_system` reads the row
// by pointer rather than copying 24 bytes onto the stack per entity per tick.
@(rodata)
entity_definitions := [Entity_Kind]Entity_Definition {
	.Player = {
		max_health = 100,
		movement = {
			move_speed     = 110,
			jump_speed     = 260,
			gravity        = 900,
			max_fall_speed = 640,
			ground_damping = 18,
			air_control    = 0.55,
		},
		collider = {12, 20},
		texture  = .Player,
		tint     = {236, 226, 196, 255},
		depth    = 10,
	},
	.Walker = {
		max_health = 30,
		movement = {
			move_speed     = 42,
			jump_speed     = 200,
			gravity        = 900,
			max_fall_speed = 640,
			ground_damping = 14,
			air_control    = 0.3,
		},
		collider = {12, 14},
		texture  = .Creature,
		tint     = {180, 96, 120, 255},
		depth    = 5,
	},
	.Coin = {
		collider = {8, 8},
		texture  = .Item,
		tint     = {230, 196, 84, 255},
		depth    = 4,
	},
	.Rock = {
		collider = {8, 8},
		texture  = .Item,
		tint     = {150, 148, 142, 255},
		depth    = 4,
	},
	// A fireball has no `move_speed` or `jump_speed`: it is not driven by
	// intent, so `movement_system` never sees it. What it does need from this
	// row is gravity, which `projectile_system` reads from here rather than
	// carrying a private copy on every shot in flight.
	.Fireball = {
		movement = {gravity = 520, max_fall_speed = 640},
		collider = {6, 6},
		texture  = .Projectile,
		tint     = {240, 148, 56, 255},
		depth    = 8,
	},
}

Identity :: struct {
	kind: ecs.Sparse_Set(Entity_Kind),
}

Identity_Snapshot :: struct {
	kind: Entity_Kind,
}

// The row an entity was spawned from. Zero for a handle with no kind, so a
// caller holding a stale handle reads zeroes rather than faulting.
definition_of :: proc(id: ^Identity, e: ecs.Entity) -> Entity_Definition {
	k := ecs.get(&id.kind, e)
	if k == nil {
		return {}
	}
	return entity_definitions[k^]
}

identity_destroy :: proc(id: ^Identity) {
	ecs.set_destroy(&id.kind)
}

identity_detach :: proc(id: ^Identity, e: ecs.Entity) {
	ecs.remove(&id.kind, e)
}

identity_save :: proc(w: ^serial.Writer, id: ^Identity) {
	serial.put_set(w, &id.kind)
}

identity_load :: proc(r: ^serial.Reader, id: ^Identity) -> bool {
	serial.take_set(r, &id.kind) or_return
	return true
}

identity_capture :: proc(id: ^Identity, e: ecs.Entity, snap: ^Identity_Snapshot) -> Component_Flags {
	present: Component_Flags
	if v := ecs.get(&id.kind, e); v != nil {snap.kind = v^;present += {.Kind}}
	return present
}

identity_restore :: proc(id: ^Identity, e: ecs.Entity, snap: Identity_Snapshot, present: Component_Flags) {
	if .Kind in present {ecs.add(&id.kind, e, snap.kind)}
}
