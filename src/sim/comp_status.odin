package sim

import "../ecs"
import "../serial"

// Current value only; the maximum is per kind and lives in
// `entity_definitions`.
Health :: struct {
	current: f32,
}

Status :: struct {
	health: ecs.Sparse_Set(Health),
}

Status_Snapshot :: struct {
	health: Health,
}

status_destroy :: proc(st: ^Status) {
	ecs.set_destroy(&st.health)
}

status_detach :: proc(st: ^Status, e: ecs.Entity) {
	ecs.remove(&st.health, e)
}

status_save :: proc(w: ^serial.Writer, st: ^Status) {
	serial.put_set(w, &st.health)
}

status_load :: proc(r: ^serial.Reader, st: ^Status) -> bool {
	serial.take_set(r, &st.health) or_return
	return true
}

status_capture :: proc(st: ^Status, e: ecs.Entity, snap: ^Status_Snapshot) -> Component_Flags {
	present: Component_Flags
	if v := ecs.get(&st.health, e); v != nil {snap.health = v^;present += {.Health}}
	return present
}

status_restore :: proc(st: ^Status, e: ecs.Entity, snap: Status_Snapshot, present: Component_Flags) {
	if .Health in present {ecs.add(&st.health, e, snap.health)}
}
