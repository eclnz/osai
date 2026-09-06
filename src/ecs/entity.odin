package ecs

// Entities are IDs. Nothing more.
//
// An entity is a slot index plus a generation counter. The generation is
// bumped every time a slot is reused, so a handle held across a destroy
// compares unequal to whatever now lives in that slot. That is the whole
// stale-reference story: no null checks, no back-pointers, no ownership.

Entity :: struct {
	index:      u32,
	generation: u32,
}

// A handle that can never match a live slot. `index` is out of range for any
// store that has not allocated 4 billion entities.
NIL :: Entity{index = max(u32), generation = 0}

Entity_Store :: struct {
	// Parallel arrays indexed by slot. `generations[i]` is the generation of
	// whatever currently occupies slot i; `alive[i]` says whether anything does.
	generations: [dynamic]u32,
	alive:       [dynamic]bool,

	// Slots that have been destroyed and can be handed out again. Destroy
	// pushes, create pops, and we only grow the arrays when this is empty.
	free_list:   [dynamic]u32,

	live_count:  int,
}

entity_store_destroy :: proc(store: ^Entity_Store) {
	delete(store.generations)
	delete(store.alive)
	delete(store.free_list)
	store^ = {}
}

create_entity :: proc(store: ^Entity_Store) -> Entity {
	index: u32
	if len(store.free_list) > 0 {
		index = pop(&store.free_list)
		// Reusing a slot: bump the generation so old handles to it go stale.
		store.generations[index] += 1
		store.alive[index] = true
	} else {
		index = u32(len(store.generations))
		append(&store.generations, u32(0))
		append(&store.alive, true)
	}
	store.live_count += 1
	return Entity{index = index, generation = store.generations[index]}
}

// Returns false if the handle was already stale, which makes double-destroy
// harmless rather than corrupting the free list.
destroy_entity :: proc(store: ^Entity_Store, e: Entity) -> bool {
	if !is_alive(store, e) {
		return false
	}
	store.alive[e.index] = false
	append(&store.free_list, e.index)
	store.live_count -= 1
	return true
}

is_alive :: proc(store: ^Entity_Store, e: Entity) -> bool {
	if int(e.index) >= len(store.alive) {
		return false
	}
	return store.alive[e.index] && store.generations[e.index] == e.generation
}

// Number of slots ever allocated. Sparse sets size their lookup array to this.
slot_capacity :: proc(store: ^Entity_Store) -> int {
	return len(store.generations)
}
