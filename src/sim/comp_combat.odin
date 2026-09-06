package sim

import "../ecs"
import "../serial"

// `Weapon` is the capacity to fire, `Projectile` what is in flight. Neither
// knows what is carrying it: the player has a weapon because `spawn_player`
// gives it one.

// Seconds remaining, counted down by `weapon_system`. A shot is refused while
// it is above zero, so fire rate does not depend on how fast the key is
// pressed or how many catch-up steps a frame ran.
Weapon :: struct {
	cooldown: f32,
}

WEAPON_COOLDOWN :: f32(0.35)

// Muzzle speed, in world units per second.
FIREBALL_SPEED :: f32(300)
FIREBALL_DAMAGE :: f32(18)
// Without this, every shot that flies off into open sky stays resident.
FIREBALL_LIFETIME :: f32(4)

Projectile :: struct {
	// Excluded from its own damage: a shot fired while running forward spawns
	// inside the shooter's box.
	owner:  ecs.Entity,
	damage: f32,
	// Seconds left before it expires.
	life:   f32,
}

Combat :: struct {
	weapon:     ecs.Sparse_Set(Weapon),
	projectile: ecs.Sparse_Set(Projectile),
}

Combat_Snapshot :: struct {
	weapon:     Weapon,
	projectile: Projectile,
}

combat_destroy :: proc(c: ^Combat) {
	ecs.set_destroy(&c.weapon)
	ecs.set_destroy(&c.projectile)
}

combat_detach :: proc(c: ^Combat, e: ecs.Entity) {
	ecs.remove(&c.weapon, e)
	ecs.remove(&c.projectile, e)
}

// Write order is the read order in `combat_load`.
combat_save :: proc(w: ^serial.Writer, c: ^Combat) {
	serial.put_set(w, &c.weapon)
	serial.put_set(w, &c.projectile)
}

combat_load :: proc(r: ^serial.Reader, c: ^Combat) -> bool {
	serial.take_set(r, &c.weapon) or_return
	serial.take_set(r, &c.projectile) or_return
	return true
}

combat_capture :: proc(c: ^Combat, e: ecs.Entity, snap: ^Combat_Snapshot) -> Component_Flags {
	present: Component_Flags
	if v := ecs.get(&c.weapon, e); v != nil {snap.weapon = v^;present += {.Weapon}}
	if v := ecs.get(&c.projectile, e); v != nil {snap.projectile = v^;present += {.Projectile}}
	return present
}

combat_restore :: proc(c: ^Combat, e: ecs.Entity, snap: Combat_Snapshot, present: Component_Flags) {
	if .Weapon in present {ecs.add(&c.weapon, e, snap.weapon)}
	if .Projectile in present {ecs.add(&c.projectile, e, snap.projectile)}
}
