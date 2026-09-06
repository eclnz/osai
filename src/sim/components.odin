package sim

import "../world"

Vec2 :: [2]f32

// Component arrays.
//
// Every type here is plain old data: no pointers, no dynamic arrays, no
// methods. That is what lets persistence be "write the arrays out" and what
// lets a component be copied into a dormant entity blob without a deep copy.
//
// Absence of a component *is* the declaration. There is no `has_health` flag
// anywhere, because an entity with no entry in the health array cannot be
// damaged - the damage system simply does not find it.

// ---------------------------------------------------------------- spatial

Collider :: struct {
	// Axis-aligned box, anchored at the entity position (top-left).
	size: Vec2,
}

Grounded :: struct {
	// Entities that can stand on something have this component; the flag says
	// whether they currently are. Adding and removing a component every frame
	// would be churn for no gain.
	on_ground: bool,
}

// ---------------------------------------------------------------- control

Intent :: struct {
	horizontal:     f32, // -1 .. 1
	jump_requested: bool,
}

Movement_Params :: struct {
	move_speed:       f32,
	jump_speed:       f32,
	gravity:          f32,
	max_fall_speed:   f32,
	// Ground friction as a fraction of speed shed per second.
	ground_damping:   f32,
	air_control:      f32,
}

AI_Behaviour :: enum u8 {
	Idle,
	Patrol,
}

AI_State :: struct {
	behaviour: AI_Behaviour,
	// Whatever the behaviour needs. Patrol uses `facing`; Idle uses nothing.
	facing:    f32,
	timer:     f32,
}

// ------------------------------------------------------------------- life

Health :: struct {
	current: f32,
	max:     f32,
}

// ----------------------------------------------------------- presentation

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

Animation_Id :: enum u8 {
	Idle,
	Run,
	Jump,
	Fall,
	Hurt,
	Death,
}

Animation_State :: struct {
	current:          Animation_Id,
	elapsed:          f32,
	frame:            int,

	// A command outranks derivation while it is unexpired. See animation.odin.
	commanded:        Animation_Id,
	command_priority: u8,
	command_expiry:   f32,
}

Sprite :: struct {
	// Source rectangle in the texture. Written by animation, read by rendering.
	source: Rect,
	flip_x: bool,
}

Rect :: struct {
	x, y, w, h: f32,
}

Layer :: struct {
	depth: i16,
}

// -------------------------------------------------------------- inventory

Item_Id :: enum u8 {
	None,
	Coin,
	Rock,
}

Item_Definition :: struct {
	name:       string,
	stackable:  bool,
	max_stack:  u16,
	space_cost: u8,
}

// Indexed by type ID. Not saved.
item_definitions := [Item_Id]Item_Definition {
	.None = {name = "", stackable = false, max_stack = 0, space_cost = 0},
	.Coin = {name = "coin", stackable = true, max_stack = 999, space_cost = 1},
	.Rock = {name = "rock", stackable = true, max_stack = 32, space_cost = 1},
}

INVENTORY_SLOTS :: 8

Item_Slot :: struct {
	item:  Item_Id,
	count: u16,
}

Inventory :: struct {
	slots: [INVENTORY_SLOTS]Item_Slot,
}

// Capacity and organisation models are deliberately unresolved; this is the
// smallest thing that lets the pickup queue be drained into something real.
inventory_add :: proc(inv: ^Inventory, item: Item_Id, count: u16) -> (added: u16) {
	remaining := count
	def := item_definitions[item]

	if def.stackable {
		for &slot in inv.slots {
			if slot.item != item || slot.count >= def.max_stack {
				continue
			}
			space := def.max_stack - slot.count
			take := min(space, remaining)
			slot.count += take
			remaining -= take
			if remaining == 0 {
				return count
			}
		}
	}

	for &slot in inv.slots {
		if slot.item != .None {
			continue
		}
		take := def.stackable ? min(def.max_stack, remaining) : 1
		slot = {item = item, count = take}
		remaining -= take
		if remaining == 0 {
			return count
		}
	}
	return count - remaining
}

// ------------------------------------------------------------------ world

// Re-exported so callers of `sim` do not have to import `world` for the
// handful of constants they need.
TILE_SIZE :: world.TILE_SIZE
