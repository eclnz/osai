package serial

import "../ecs"

// Byte plumbing. A cursor over a buffer, length-prefixed arrays, and blits of
// plain-old-data values - nothing here knows what a simulation is.
//
// It lives below `sim` because the component groups need it. A group's
// `_save`/`_load` list belongs next to the group's declaration, which means
// the group file has to reach for a writer; if that writer lived in `sim`, the
// groups would depend upward on the thing that aggregates them.
//
// The `_set` helpers make this package depend on `ecs`. That is the right
// direction - `ecs` is a leaf, and the alternative, teaching `ecs` to
// serialise itself, would point the dependency the wrong way.

// ------------------------------------------------------------------ writer

Writer :: struct {
	buf: [dynamic]u8,
}

put :: proc(w: ^Writer, value: $T) {
	// Every saved type is POD, so its bytes are its state. That is a property
	// of the component types, not of this procedure - a component holding a
	// pointer would compile here and produce a corrupt save.
	v := value
	bytes := transmute(^[size_of(T)]u8)(&v)
	append(&w.buf, ..bytes[:])
}

// Length prefix and payload in one place, so the two cannot drift apart.
put_array :: proc(w: ^Writer, values: []$T) {
	put(w, u32(len(values)))
	for v in values {put(w, v)}
}

put_set :: proc(w: ^Writer, s: ^ecs.Sparse_Set($T)) {
	put(w, u32(len(s.dense)))
	for value, i in s.dense {
		put(w, s.owners[i])
		put(w, value)
	}
}

// ------------------------------------------------------------------ reader

Reader :: struct {
	buf: []u8,
	off: int,
}

take :: proc(r: ^Reader, $T: typeid) -> (value: T, ok: bool) {
	if r.off + size_of(T) > len(r.buf) {
		return {}, false
	}
	bytes := transmute(^[size_of(T)]u8)(&value)
	copy(bytes[:], r.buf[r.off:][:size_of(T)])
	r.off += size_of(T)
	return value, true
}

take_array :: proc(r: ^Reader, a: ^[dynamic]$T) -> bool {
	n := take(r, u32) or_return
	resize(a, int(n))
	for i in 0 ..< int(n) {
		a^[i] = take(r, T) or_return
	}
	return true
}

take_set :: proc(r: ^Reader, s: ^ecs.Sparse_Set($T)) -> bool {
	n := take(r, u32) or_return
	for _ in 0 ..< n {
		owner := take(r, ecs.Entity) or_return
		value := take(r, T) or_return
		ecs.add(s, owner, value)
	}
	return true
}
