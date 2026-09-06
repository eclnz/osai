package sim

import "../ecs"
import "../serial"
import "core:os"

SAVE_MAGIC :: u32(0x4941534f) // "OSAI"
SAVE_VERSION :: u32(2)

Save_Error :: enum {
	None,
	Cannot_Write,
	Cannot_Read,
	Bad_Magic,
	Bad_Version,
	Truncated,
}

// -------------------------------------------------------------------- save

save_to_file :: proc(s: ^State, path: string) -> Save_Error {
	w: serial.Writer
	defer delete(w.buf)

	serial.put(&w, SAVE_MAGIC)
	serial.put(&w, SAVE_VERSION)
	serial.put(&w, s.seed)
	serial.put(&w, s.tick)
	serial.put(&w, s.player)

	// entity slots
	serial.put_array(&w, s.entities.generations[:])
	serial.put_array(&w, s.entities.free_list[:])
	serial.put(&w, i64(s.entities.live_count))

	// component arrays
	identity_save(&w, &s.identity)
	spatial_save(&w, &s.spatial)
	control_save(&w, &s.control)
	status_save(&w, &s.status)
	presentation_save(&w, &s.presentation)
	items_save(&w, &s.items)

	// pending work, so a save taken mid-carryover does not drop it
	events_save(&w, &s.events)

	// dormant entities and chunk bookkeeping
	residency_save(&w, &s.residency)

	terrain_save(&w, &s.terrain)

	if err := os.write_entire_file(path, w.buf[:]); err != nil {
		return .Cannot_Write
	}
	return .None
}

// -------------------------------------------------------------------- load

// Replaces everything in `s`. The state that comes back is the state that
// went in, including entity handles: generations are restored, so a handle
// saved alongside the world still resolves.
load_from_file :: proc(s: ^State, path: string) -> Save_Error {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return .Cannot_Read
	}
	defer delete(data)

	r := serial.Reader {
		buf = data,
	}

	magic := serial.take(&r, u32) or_else 0
	if magic != SAVE_MAGIC {
		return .Bad_Magic
	}
	version := serial.take(&r, u32) or_else 0
	if version != SAVE_VERSION {
		return .Bad_Version
	}

	seed := serial.take(&r, u64) or_else 0
	state_destroy(s)
	state_init(s, seed)

	tick, tick_ok := serial.take(&r, u64)
	if !tick_ok {return .Truncated}
	s.tick = tick

	player, player_ok := serial.take(&r, ecs.Entity)
	if !player_ok {return .Truncated}
	s.player = player

	if !load_body(s, &r) {
		return .Truncated
	}
	return .None
}

@(private="file")
load_body :: proc(s: ^State, r: ^serial.Reader) -> bool {
	serial.take_array(r, &s.entities.generations) or_return
	serial.take_array(r, &s.entities.free_list) or_return
	live := serial.take(r, i64) or_return
	s.entities.live_count = int(live)

	identity_load(r, &s.identity) or_return
	spatial_load(r, &s.spatial) or_return
	control_load(r, &s.control) or_return
	status_load(r, &s.status) or_return
	presentation_load(r, &s.presentation) or_return
	items_load(r, &s.items) or_return

	events_load(r, &s.events) or_return
	residency_load(r, &s.residency) or_return

	terrain_load(r, &s.terrain) or_return
	terrain_regenerate_resident(&s.terrain, s.residency.resident, s.seed)

	return true
}
