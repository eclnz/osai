package sim

import "../ecs"

// Which entities are near which. One grid serves every kind of overlap: each
// interaction asks the same structure and then filters by component presence,
// so a new one is a new small system rather than another N-by-M loop.
//
// Rebuilt each tick into the temp allocator. Nothing reads it between ticks,
// and rebuilding is cheaper than keeping it correct under movement.

// World units, sized so a collider fits in one cell - which is what lets an
// entity be filed under a single cell instead of every cell it touches. The
// assert in `broadphase_build` holds that.
BROADPHASE_CELL :: f32(32)

Broadphase :: struct {
	// Counting-sort buckets: `starts` has `buckets + 1` entries, and the
	// entries for bucket b are items[starts[b] : starts[b + 1]].
	starts: []u32,
	items:  []ecs.Entity,
	// Parallel to `items`, so the narrow phase re-tests overlap without a
	// sparse lookup per candidate.
	boxes:   []AABB,
	buckets: u32,
}

@(private = "file")
cell_of :: proc(p: Vec2) -> [2]i32 {
	// Floor, not truncate: the cells either side of the origin must not fold
	// into one.
	cx := i32(p.x / BROADPHASE_CELL)
	cy := i32(p.y / BROADPHASE_CELL)
	if p.x < 0 && f32(cx) * BROADPHASE_CELL != p.x {cx -= 1}
	if p.y < 0 && f32(cy) * BROADPHASE_CELL != p.y {cy -= 1}
	return {cx, cy}
}

@(private = "file")
bucket_of :: proc(cell: [2]i32, buckets: u32) -> u32 {
	// The world is unbounded, so cells hash into a fixed table. A collision
	// only means a few extra narrow-phase tests.
	h := u32(cell.x) * 0x9E3779B1 + u32(cell.y) * 0x85EBCA77
	h ~= h >> 15
	return h & (buckets - 1)
}

// Counting sort: count per bucket, then place. No per-bucket dynamic arrays,
// so the result is contiguous and nothing churns.
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

	// Gathered once so the placement pass does not re-query the sparse sets.
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

// Appends indices addressing `bp.items` and `bp.boxes` together.
//
// Widened by one cell on the minimum side because entities are filed by the
// cell of their top-left corner, so a neighbour filed in the previous cell can
// still reach into this one. Exact as long as no collider exceeds a cell.
broadphase_query :: proc(bp: ^Broadphase, box: AABB, out: ^[dynamic]u32) {
	lo := cell_of({box.min.x - BROADPHASE_CELL, box.min.y - BROADPHASE_CELL})
	hi := cell_of(box.max)

	// Two cells can hash to one bucket and report its occupants twice. The
	// scan is a few cells, so a linear check beats any set.
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
