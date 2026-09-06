package tests

import "../src/ecs"
import "core:testing"

@(test)
sparse_set_add_get_remove :: proc(t: ^testing.T) {
	store: ecs.Entity_Store
	defer ecs.entity_store_destroy(&store)

	set: ecs.Sparse_Set(int)
	defer ecs.set_destroy(&set)

	a := ecs.create_entity(&store)
	b := ecs.create_entity(&store)
	c := ecs.create_entity(&store)

	ecs.add(&set, a, 1)
	ecs.add(&set, b, 2)
	ecs.add(&set, c, 3)
	testing.expect_value(t, ecs.count(&set), 3)

	// Removing the middle element swaps the last one into its place; the
	// swapped element must still be findable by its own handle.
	testing.expect(t, ecs.remove(&set, b))
	testing.expect_value(t, ecs.count(&set), 2)
	testing.expect(t, !ecs.has(&set, b))
	testing.expect_value(t, ecs.get(&set, a)^, 1)
	testing.expect_value(t, ecs.get(&set, c)^, 3)

	// Adding a component an entity already has overwrites rather than
	// duplicating.
	ecs.add(&set, a, 42)
	testing.expect_value(t, ecs.count(&set), 2)
	testing.expect_value(t, ecs.get(&set, a)^, 42)
}

@(test)
generation_invalidates_stale_handles :: proc(t: ^testing.T) {
	store: ecs.Entity_Store
	defer ecs.entity_store_destroy(&store)

	set: ecs.Sparse_Set(int)
	defer ecs.set_destroy(&set)

	old := ecs.create_entity(&store)
	ecs.add(&set, old, 7)
	testing.expect(t, ecs.destroy_entity(&store, old))
	testing.expect(t, !ecs.is_alive(&store, old))
	testing.expect(t, !ecs.destroy_entity(&store, old), "double destroy must be a no-op")

	// The slot comes back with a new generation, so the stale handle must not
	// resolve to the new occupant's component.
	fresh := ecs.create_entity(&store)
	testing.expect_value(t, fresh.index, old.index)
	testing.expect(t, fresh.generation != old.generation)

	ecs.add(&set, fresh, 9)
	testing.expect(t, !ecs.has(&set, old))
	testing.expect_value(t, ecs.get(&set, fresh)^, 9)
	testing.expect(t, ecs.get(&set, old) == nil)
}

@(test)
free_list_reuses_before_growing :: proc(t: ^testing.T) {
	store: ecs.Entity_Store
	defer ecs.entity_store_destroy(&store)

	a := ecs.create_entity(&store)
	b := ecs.create_entity(&store)
	testing.expect_value(t, ecs.slot_capacity(&store), 2)

	ecs.destroy_entity(&store, a)
	ecs.destroy_entity(&store, b)
	testing.expect_value(t, store.live_count, 0)

	ecs.create_entity(&store)
	ecs.create_entity(&store)
	testing.expect_value(t, ecs.slot_capacity(&store), 2)
	testing.expect_value(t, store.live_count, 2)
}
