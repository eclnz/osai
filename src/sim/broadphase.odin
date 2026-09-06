package sim

import "../ecs"

// Which entities are near which, so that an interaction system does not have
// to look at every entity to find the few it cares about.
//
// One grid serves every kind of overlap. A system that wants "creatures near
// this arrow" and one that wants "items near this collector" ask the same
// structure and then filter by component presence - so a new interaction is a
// new small system, not a change to an existing one and not another N-by-M
// loop over two arrays.
//
// Built fresh each tick into the temp allocator. It is scratch derived from
// position and collider, never state: nothing reads it between ticks, nothing
// saves it, and rebuilding is cheaper than keeping it correct under movement.

// Cell size in world units. Chosen so that a collider fits inside one cell,
// which is what lets an entity be filed under a single cell instead of every
// cell it touches - see the assert in `broadphase_build`.
BROADPHASE_CELL :: f32(32)

Broadphase :: struct {
	// Counting-sort buckets: `starts` has `buckets + 1` entries, and the
	// entries for bucket b are items[starts[b] : starts[b + 1]].
	starts: []u32,
	items:  []ecs.Entity,
	// Parallel to `items`, so the narrow phase re-tests overlap without a
	// sparse lookup per candidate. This is most of the point.
	boxes:   []AABB,
	buckets: u32,
}

@(private = "file")
cell_of :: proc(p: Vec2) -> [2]i32 {
	// Floor, not truncate: the cell either side of the origin must not fold
	// into one, same reason `tile_coord_of_world` does it.
	cx := i32(p.x / BROADPHASE_CELL)
	cy := i32(p.y / BROADPHASE_CELL)
	if p.x < 0 && f32(cx) * BROADPHASE_CELL != p.x {cx -= 1}
	if p.y < 0 && f32(cy) * BROADPHASE_CELL != p.y {cy -= 1}
	return {cx, cy}
}

@(private = "file")
bucket_of :: proc(cell: [2]i32, buckets: u32) -> u32 {
	// The world is unbounded, so cells hash into a fixed table rather than
	// indexing one. Collisions just mean a few extra narrow-phase tests.
	h := u32(cell.x) * 0x9E3779B1 + u32(cell.y) * 0x85EBCA77
	h ~= h >> 15
	return h & (buckets - 1)
}

// Files every entity that has both a collider and a position. Two passes:
// count per bucket, then place. No per-bucket dynamic arrays, so no
// allocation churn and the result is contiguous.
broadphase_build :: proc(s: ^State, allocator := context.temp_allocator) -> Broadphase {
	n := len(s.spatial.collider.dense)

	buckets := u32(64)
	for buckets < u32(n) * 2 {
		buckets <<= 1
	}

	bp := Broadphase {
		buckets = buckets,
		starts  = make([]u32, buckets + 1, allocator),
		items   = make([]ecs.Entity, n, allocator),
		boxes   = make([]AABB, n, allocator),
	}
	if n == 0 {
		return bp
	}

	// Gather once: the second pass re-reads these instead of re-querying the
	// sparse sets.
	ents := make([]ecs.Entity, n, allocator)
	boxes := make([]AABB, n, allocator)
	slots := make([]u32, n, allocator)
	count := 0

	for col, i in s.spatial.collider.dense {
		e := s.spatial.collider.owners[i]
		pos := ecs.get(&s.spatial.position, e)
		if pos == nil {
			continue
		}
		assert(
			col.size.x <= BROADPHASE_CELL && col.size.y <= BROADPHASE_CELL,
			"collider larger than a broadphase cell would be missed by queries",
		)
		ents[count] = e
		boxes[count] = aabb_of(pos^, col)
		slots[count] = bucket_of(cell_of(pos^), buckets)
		count += 1
	}

	for i in 0 ..< count {
		bp.starts[slots[i] + 1] += 1
	}
	for b in u32(1) ..= buckets {
		bp.starts[b] += bp.starts[b - 1]
	}

	cursor := make([]u32, buckets, allocator)
	for i in 0 ..< count {
		b := slots[i]
		at := bp.starts[b] + cursor[b]
		bp.items[at] = ents[i]
		bp.boxes[at] = boxes[i]
		cursor[b] += 1
	}

	bp.items = bp.items[:count]
	bp.boxes = bp.boxes[:count]
	return bp
}

// Appends the indices of every entity filed near `box`. Indices address
// `bp.items` and `bp.boxes` together.
//
// The scan is widened by one cell on the minimum side because entities are
// filed by the cell of their top-left corner: a neighbour whose corner sits in
// the previous cell can still reach into this one. That is exact as long as no
// collider exceeds a cell, which `broadphase_build` asserts.
broadphase_query :: proc(bp: ^Broadphase, box: AABB, out: ^[dynamic]u32) {
	lo := cell_of({box.min.x - BROADPHASE_CELL, box.min.y - BROADPHASE_CELL})
	hi := cell_of(box.max)

	// Two distinct cells can hash to one bucket, which would report its
	// occupants twice. The scan is at most a few cells, so a linear check
	// against the buckets already visited is cheaper than any set.
	seen: [16]u32
	seen_n := 0

	outer: for cy in lo.y ..= hi.y {
		for cx in lo.x ..= hi.x {
			b := bucket_of({cx, cy}, bp.buckets)
			for i in 0 ..< seen_n {
				if seen[i] == b {
					continue outer
				}
			}
			if seen_n < len(seen) {
				seen[seen_n] = b
				seen_n += 1
			}
			for i in bp.starts[b] ..< bp.starts[b + 1] {
				append(out, i)
			}
		}
	}
}
