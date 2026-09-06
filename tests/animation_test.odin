package tests

import "../src/ecs"
import "../src/sim"
import "core:testing"

@(private)
anim_of :: proc(s: ^sim.State, e: ecs.Entity) -> sim.Animation_Id {
	return ecs.get(&s.presentation.animation, e).current
}

@(test)
animation_derives_from_velocity_and_grounded :: proc(t: ^testing.T) {
	s: sim.State
	flat_state(&s)
	defer sim.state_destroy(&s)

	e := sim.spawn_player(&s, {40, 0})
	vel := ecs.get(&s.spatial.velocity, e)
	grounded := ecs.get(&s.spatial.grounded, e)

	grounded.on_ground = true
	vel^ = {0, 0}
	sim.animation_system(&s, 0.016)
	testing.expect_value(t, anim_of(&s, e), sim.Animation_Id.Idle)

	// Nothing told the animation system the entity started running.
	vel^ = {80, 0}
	sim.animation_system(&s, 0.016)
	testing.expect_value(t, anim_of(&s, e), sim.Animation_Id.Run)

	grounded.on_ground = false
	vel^ = {80, -120}
	sim.animation_system(&s, 0.016)
	testing.expect_value(t, anim_of(&s, e), sim.Animation_Id.Jump)

	vel^ = {80, 200}
	sim.animation_system(&s, 0.016)
	testing.expect_value(t, anim_of(&s, e), sim.Animation_Id.Fall)
}

@(test)
commands_outrank_derivation_until_they_expire :: proc(t: ^testing.T) {
	s: sim.State
	flat_state(&s)
	defer sim.state_destroy(&s)

	e := sim.spawn_player(&s, {40, 0})
	ecs.get(&s.spatial.grounded, e).on_ground = true
	ecs.get(&s.spatial.velocity, e)^ = {80, 0}

	sim.animation_system(&s, 0.016)
	testing.expect_value(t, anim_of(&s, e), sim.Animation_Id.Run)

	// Hurt is not visible in movement data, so a system has to say so.
	sim.command_animation(&s, e, .Hurt, 200, 0.30)
	sim.animation_system(&s, 0.016)
	testing.expect_value(t, anim_of(&s, e), sim.Animation_Id.Hurt)

	// Priority is what stops the run derivation stomping it on the next frame.
	sim.animation_system(&s, 0.016)
	testing.expect_value(t, anim_of(&s, e), sim.Animation_Id.Hurt)

	// A lower-priority command must not displace one already in flight.
	sim.command_animation(&s, e, .Idle, 10, 1.0)
	sim.animation_system(&s, 0.016)
	testing.expect_value(t, anim_of(&s, e), sim.Animation_Id.Hurt)

	// Expiry hands control back to derivation with nothing having to clear it.
	sim.animation_system(&s, 0.40)
	testing.expect_value(t, anim_of(&s, e), sim.Animation_Id.Run)
}

@(test)
non_looping_commands_expire_on_completion :: proc(t: ^testing.T) {
	s: sim.State
	flat_state(&s)
	defer sim.state_destroy(&s)

	e := sim.spawn_player(&s, {40, 0})
	ecs.get(&s.spatial.grounded, e).on_ground = true
	ecs.get(&s.spatial.velocity, e)^ = {0, 0}

	// Hurt is 2 frames at 0.10s; a 10 second command still ends after 0.20s
	// of animation, because completion expires it too.
	sim.command_animation(&s, e, .Hurt, 200, 10.0)
	sim.animation_system(&s, 0.016)
	testing.expect_value(t, anim_of(&s, e), sim.Animation_Id.Hurt)

	sim.animation_system(&s, 0.25)
	sim.animation_system(&s, 0.016)
	testing.expect_value(t, anim_of(&s, e), sim.Animation_Id.Idle)
}

@(test)
damage_writes_an_animation_command_without_calling_animation :: proc(t: ^testing.T) {
	s: sim.State
	flat_state(&s)
	defer sim.state_destroy(&s)

	e := sim.spawn_player(&s, {40, 0})
	append(&s.events.damage, sim.Damage_Event{target = e, amount = 5})
	sim.drain_damage(&s)

	// The damage drain wrote a field. It did not animate anything, and the
	// animation state is untouched until the animation system runs.
	anim := ecs.get(&s.presentation.animation, e)
	testing.expect_value(t, anim.commanded, sim.Animation_Id.Hurt)
	testing.expect(t, anim.command_expiry > 0)
	testing.expect_value(t, anim.current, sim.Animation_Id.Idle)

	sim.animation_system(&s, 0.016)
	testing.expect_value(t, anim_of(&s, e), sim.Animation_Id.Hurt)
}

// Facing is a simulation fact, not a render flag: the sim publishes a
// direction and the renderer decides what that means in a texture. So there is
// nothing in pixels to assert here, only the direction and its stickiness.
@(test)
facing_follows_velocity_and_is_sticky :: proc(t: ^testing.T) {
	s: sim.State
	flat_state(&s)
	defer sim.state_destroy(&s)

	e := sim.spawn_player(&s, {40, 0})
	// Neither pointer is invalidated below: facing_system only mutates.
	facing := ecs.get(&s.spatial.facing, e)
	vel := ecs.get(&s.spatial.velocity, e)

	testing.expect_value(t, facing^, sim.Facing(1)) // spawns facing right

	vel^ = {-80, 0}
	sim.facing_system(&s, sim.FIXED_DT)
	testing.expect_value(t, facing^, sim.Facing(-1))

	// Sticky: stopping does not snap the entity back to facing right.
	vel^ = {0, 0}
	sim.facing_system(&s, sim.FIXED_DT)
	testing.expect_value(t, facing^, sim.Facing(-1))

	// Nor does drift below the deadband, which is what makes it sticky.
	vel^ = {0.5, 0}
	sim.facing_system(&s, sim.FIXED_DT)
	testing.expect_value(t, facing^, sim.Facing(-1))

	vel^ = {80, 0}
	sim.facing_system(&s, sim.FIXED_DT)
	testing.expect_value(t, facing^, sim.Facing(1))
}

// Facing runs inside the fixed step, so a tick alone is enough to update it -
// no frame-rate system involved.
@(test)
facing_updates_within_the_fixed_step :: proc(t: ^testing.T) {
	s: sim.State
	flat_state(&s)
	defer sim.state_destroy(&s)

	e := sim.spawn_player(&s, {40, 0})
	ecs.get(&s.control.intent, e).horizontal = -1

	for _ in 0 ..< 10 {
		sim.fixed_step(&s)
	}
	testing.expect_value(t, ecs.get(&s.spatial.facing, e)^, sim.Facing(-1))
}
