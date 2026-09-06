package sim

import "../ecs"
import "../serial"

// Two sides of one idea: `inventory` is what an entity holds, `item` is what
// an entity is while lying on the ground. The pickup drain moves one into the
// other and destroys the entity.

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

// Indexed by type ID. Not saved - see entity_definitions. `@(rodata)` has no
// effect here in practice: `name` is a string, and its relocation keeps the
// table in writable data. Kept for the intent.
@(rodata)
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

// Capacity and organisation models are deliberately unresolved.
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


Items :: struct {
	inventory: ecs.Sparse_Set(Inventory),
	item:      ecs.Sparse_Set(Item_Slot),
}

Items_Snapshot :: struct {
	inventory: Inventory,
	item:      Item_Slot,
}

items_destroy :: proc(it: ^Items) {
	ecs.set_destroy(&it.inventory)
	ecs.set_destroy(&it.item)
}

items_detach :: proc(it: ^Items, e: ecs.Entity) {
	ecs.remove(&it.inventory, e)
	ecs.remove(&it.item, e)
}

// Write order is the read order in `items_load`.
items_save :: proc(w: ^serial.Writer, it: ^Items) {
	serial.put_set(w, &it.inventory)
	serial.put_set(w, &it.item)
}

items_load :: proc(r: ^serial.Reader, it: ^Items) -> bool {
	serial.take_set(r, &it.inventory) or_return
	serial.take_set(r, &it.item) or_return
	return true
}

items_capture :: proc(it: ^Items, e: ecs.Entity, snap: ^Items_Snapshot) -> Component_Flags {
	present: Component_Flags
	if v := ecs.get(&it.inventory, e); v != nil {snap.inventory = v^;present += {.Inventory}}
	if v := ecs.get(&it.item, e); v != nil {snap.item = v^;present += {.Item}}
	return present
}

items_restore :: proc(it: ^Items, e: ecs.Entity, snap: Items_Snapshot, present: Component_Flags) {
	if .Inventory in present {ecs.add(&it.inventory, e, snap.inventory)}
	if .Item in present {ecs.add(&it.item, e, snap.item)}
}
