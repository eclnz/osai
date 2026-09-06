package ecs

// Components are plain data in arrays. No methods, no behaviour.
//
// A sparse set is two arrays and a lookup:
//
//   dense   the component values, packed with no holes
//   owners  which entity owns dense[i]  (parallel to dense)
//   sparse  entity slot index -> dense index, or NO_INDEX
//
// Iterating `dense` is pure sequential access, which is the entire point.
// Reading a *second* component for the same entity costs one indirection
// through `sparse`. Archetype storage would remove that indirection at the
// cost of migration; see docs/SPEC.md for why we are not doing that yet.
//
// The spec says "a map from entity ID to dense index". We use a flat array
// indexed by slot rather than a hash map: entity slots are small dense
// integers already, so a map would only add hashing to a problem that is
// solved by an offset.

NO_INDEX :: max(u32)

Sparse_Set :: struct($T: typeid) {
	dense:  [dynamic]T,
	owners: [dynamic]Entity,
	sparse: [dynamic]u32,
}

set_destroy :: proc(s: ^Sparse_Set($T)) {
	delete(s.dense)
	delete(s.owners)
	delete(s.sparse)
	s^ = {}
}

count :: proc(s: ^Sparse_Set($T)) -> int {
	return len(s.dense)
}

@(private)
grow_sparse :: proc(s: ^Sparse_Set($T), slot: u32) {
	old := len(s.sparse)
	if int(slot) < old {
		return
	}
	resize(&s.sparse, int(slot) + 1)
	for i in old ..< len(s.sparse) {
		s.sparse[i] = NO_INDEX
	}
}

// The generation check lives here, not at every call site: a handle to a
// destroyed entity whose slot has been reused will not find the new
// occupant's component.
dense_index :: proc(s: ^Sparse_Set($T), e: Entity) -> (u32, bool) {
	if int(e.index) >= len(s.sparse) {
		return NO_INDEX, false
	}
	d := s.sparse[e.index]
	if d == NO_INDEX {
		return NO_INDEX, false
	}
	if s.owners[d] != e {
		return NO_INDEX, false
	}
	return d, true
}

has :: proc(s: ^Sparse_Set($T), e: Entity) -> bool {
	_, ok := dense_index(s, e)
	return ok
}

// Returns a pointer into `dense`, so callers can write through it. That
// pointer is invalidated by any add/remove on the same set - systems read and
// write, they do not hold.
get :: proc(s: ^Sparse_Set($T), e: Entity) -> ^T {
	d, ok := dense_index(s, e)
	if !ok {
		return nil
	}
	return &s.dense[d]
}

get_or :: proc(s: ^Sparse_Set($T), e: Entity, fallback: T) -> T {
	d, ok := dense_index(s, e)
	if !ok {
		return fallback
	}
	return s.dense[d]
}

// Adding a component an entity already has overwrites it.
add :: proc(s: ^Sparse_Set($T), e: Entity, value: T) {
	if d, ok := dense_index(s, e); ok {
		s.dense[d] = value
		return
	}
	grow_sparse(s, e.index)
	s.sparse[e.index] = u32(len(s.dense))
	append(&s.dense, value)
	append(&s.owners, e)
}

// Swap-and-pop. Order inside a component array is meaningless, so moving the
// last element into the hole is safe - it just has to be paired with fixing
// the moved element's sparse entry.
remove :: proc(s: ^Sparse_Set($T), e: Entity) -> bool {
	d, ok := dense_index(s, e)
	if !ok {
		return false
	}
	last := u32(len(s.dense) - 1)
	if d != last {
		s.dense[d] = s.dense[last]
		s.owners[d] = s.owners[last]
		s.sparse[s.owners[d].index] = d
	}
	pop(&s.dense)
	pop(&s.owners)
	s.sparse[e.index] = NO_INDEX
	return true
}

set_clear :: proc(s: ^Sparse_Set($T)) {
	clear(&s.dense)
	clear(&s.owners)
	for i in 0 ..< len(s.sparse) {
		s.sparse[i] = NO_INDEX
	}
}
