package ecs

Entity :: struct {
	index: u32,
	generation: u32,
}

NIL :: Entity{}

// A slot's generation encodes its own liveness: odd is alive, even is dead.
Entity_Store :: struct {
	generations: [dynamic]u32,
	free_list:   [dynamic]u32,
	live_count:  int,
}

entity_slot_capacity :: proc(store: ^Entity_Store) -> int {
	return len(store.generations)
}

entity_store_destroy :: proc(store: ^Entity_Store) {
	delete(store.generations)
	delete(store.free_list)
	store^ = {}
}

entity_create :: proc(store: ^Entity_Store) -> Entity {
	index: u32
	if len(store.free_list) > 0 {
		index = pop(&store.free_list)
		store.generations[index] += 1
	} else {
		index = u32(len(store.generations))
		append(&store.generations, u32(1))
	}
	store.live_count += 1
	return Entity{index = index, generation = store.generations[index]}
}

// Returns false if the handle was already stale, which makes double-destroy
// harmless rather than corrupting the free list.
entity_destroy :: proc(store: ^Entity_Store, e: Entity) -> bool {
	if !entity_is_alive(store, e) {
		return false
	}
	store.generations[e.index] += 1
	append(&store.free_list, e.index)
	store.live_count -= 1
	return true
}

// Lookups like this are not recommended in the hotpath.
entity_is_alive :: proc(store: ^Entity_Store, e: Entity) -> bool {
	if int(e.index) >= len(store.generations) {
		return false
	}
	return store.generations[e.index] == e.generation && e.generation & 1 == 1
}
