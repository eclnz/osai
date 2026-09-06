package tests

import "../src/ecs"
import "core:testing"

@(test)
sparse_set_add_get_remove :: proc(t: ^testing.T) {
	store: ecs.Entity_Store
	defer ecs.entity_store_destroy(&store)

	set: ecs.Sparse_Set(int)
	defer ecs.set_destroy(&set)

	a := ecs.entity_create(&store)
	b := ecs.entity_create(&store)
	c := ecs.entity_create(&store)

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

	// Re-adding is a shape change, so it has to be preceded by a remove -
	// `add` on an entity that already has the component is a caller bug.
	testing.expect(t, ecs.remove(&set, a))
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

	old := ecs.entity_create(&store)
	ecs.add(&set, old, 7)
	testing.expect(t, old.generation & 1 == 1, "issued handles are odd")
	testing.expect(t, ecs.entity_destroy(&store, old))

	// Destroying bumps the slot to an even generation, so the handle goes
	// stale immediately rather than waiting for the slot to be reused.
	testing.expect(t, store.generations[old.index] & 1 == 0)
	testing.expect(t, !ecs.entity_is_alive(&store, old))
	testing.expect(t, !ecs.entity_destroy(&store, old), "double destroy must be a no-op")

	// The slot comes back with a new generation, so the stale handle must not
	// resolve to the new occupant's component.
	fresh := ecs.entity_create(&store)
	testing.expect_value(t, fresh.index, old.index)
	testing.expect(t, fresh.generation != old.generation)

	ecs.add(&set, fresh, 9)
	testing.expect(t, !ecs.has(&set, old))
	testing.expect_value(t, ecs.get(&set, fresh)^, 9)
	testing.expect(t, ecs.get(&set, old) == nil)
}

@(test)
zero_value_handle_is_never_alive :: proc(t: ^testing.T) {
	store: ecs.Entity_Store
	defer ecs.entity_store_destroy(&store)

	set: ecs.Sparse_Set(int)
	defer ecs.set_destroy(&set)

	// A handle field nobody assigned is `Entity{0, 0}`. It shares an index with
	// the first entity ever created, so only the generation separates them.
	unset: ecs.Entity
	testing.expect_value(t, unset, ecs.NIL)

	first := ecs.entity_create(&store)
	testing.expect_value(t, unset.index, first.index)

	testing.expect(t, !ecs.entity_is_alive(&store, unset))
	testing.expect(t, ecs.entity_is_alive(&store, first))
	testing.expect(t, !ecs.entity_destroy(&store, unset), "zero value must not free slot 0")
	testing.expect(t, ecs.entity_is_alive(&store, first))

	ecs.add(&set, first, 7)
	testing.expect(t, !ecs.has(&set, unset))
	testing.expect(t, ecs.get(&set, unset) == nil)

	testing.expect(t, !ecs.entity_is_alive(&store, ecs.NIL))
}

@(test)
free_list_reuses_before_growing :: proc(t: ^testing.T) {
	store: ecs.Entity_Store
	defer ecs.entity_store_destroy(&store)

	a := ecs.entity_create(&store)
	b := ecs.entity_create(&store)
	testing.expect_value(t, ecs.entity_slot_capacity(&store), 2)

	ecs.entity_destroy(&store, a)
	ecs.entity_destroy(&store, b)
	testing.expect_value(t, store.live_count, 0)

	ecs.entity_create(&store)
	ecs.entity_create(&store)
	testing.expect_value(t, ecs.entity_slot_capacity(&store), 2)
	testing.expect_value(t, store.live_count, 2)
}
