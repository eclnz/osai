package sim

import "../ecs"
import "../world"

// The simulation is a bag of component arrays, a terrain, and some queues.
// There is no `Entity` object anywhere, and no system owns any of this - they
// are all handed the same `^State` and read and write the arrays they care
// about.

State :: struct {
	entities: ecs.Entity_Store,

	// spatial
	position:          ecs.Sparse_Set(Vec2),
	previous_position: ecs.Sparse_Set(Vec2),
	velocity:          ecs.Sparse_Set(Vec2),
	collider:          ecs.Sparse_Set(Collider),
	grounded:          ecs.Sparse_Set(Grounded),

	// control
	intent:   ecs.Sparse_Set(Intent),
	movement: ecs.Sparse_Set(Movement_Params),
	ai:       ecs.Sparse_Set(AI_State),

	// life
	health: ecs.Sparse_Set(Health),

	// presentation (written by the simulation, read by the renderer)
	appearance: ecs.Sparse_Set(Appearance),
	animation:  ecs.Sparse_Set(Animation_State),
	sprite:     ecs.Sparse_Set(Sprite),
	layer:      ecs.Sparse_Set(Layer),

	// inventory
	inventory: ecs.Sparse_Set(Inventory),

	// carried items, so a pickup can be destroyed by the drain
	item: ecs.Sparse_Set(Item_Slot),

	terrain: world.Terrain,
	events:  Event_Queues,

	// Entities that have streamed out of the active region, keyed by the
	// chunk they belong to. See streaming.odin.
	dormant: map[world.Chunk_Coord][dynamic]Dormant_Entity,
	// Chunks currently resident, so streaming can diff against the new set.
	resident: map[world.Chunk_Coord]bool,
	// Chunks whose populate pass has already run. A chunk that unloads and
	// reloads must regenerate its tiles but must not spawn its creatures a
	// second time - the first set went dormant, it did not disappear.
	populated: map[world.Chunk_Coord]bool,

	seed:   u64,
	tick:   u64,
	player: ecs.Entity,
}

state_init :: proc(s: ^State, seed: u64) {
	s.seed = seed
	s.player = ecs.NIL
	world.terrain_init(&s.terrain, seed)
	s.dormant = make(map[world.Chunk_Coord][dynamic]Dormant_Entity)
	s.resident = make(map[world.Chunk_Coord]bool)
	s.populated = make(map[world.Chunk_Coord]bool)
}

state_destroy :: proc(s: ^State) {
	ecs.entity_store_destroy(&s.entities)

	ecs.set_destroy(&s.position)
	ecs.set_destroy(&s.previous_position)
	ecs.set_destroy(&s.velocity)
	ecs.set_destroy(&s.collider)
	ecs.set_destroy(&s.grounded)
	ecs.set_destroy(&s.intent)
	ecs.set_destroy(&s.movement)
	ecs.set_destroy(&s.ai)
	ecs.set_destroy(&s.health)
	ecs.set_destroy(&s.appearance)
	ecs.set_destroy(&s.animation)
	ecs.set_destroy(&s.sprite)
	ecs.set_destroy(&s.layer)
	ecs.set_destroy(&s.inventory)
	ecs.set_destroy(&s.item)

	for _, &list in s.dormant {
		delete(list)
	}
	delete(s.dormant)
	delete(s.resident)
	delete(s.populated)

	events_destroy(&s.events)
	world.terrain_destroy(&s.terrain)
	s^ = {}
}

// The one place that knows the full list of component arrays. Sparse sets buy
// their flexibility with exactly this: adding an array means adding a line
// here, and the compiler will not remind you. Archetype storage would not
// need it - noted, not yet paid for.
detach_all_components :: proc(s: ^State, e: ecs.Entity) {
	ecs.remove(&s.position, e)
	ecs.remove(&s.previous_position, e)
	ecs.remove(&s.velocity, e)
	ecs.remove(&s.collider, e)
	ecs.remove(&s.grounded, e)
	ecs.remove(&s.intent, e)
	ecs.remove(&s.movement, e)
	ecs.remove(&s.ai, e)
	ecs.remove(&s.health, e)
	ecs.remove(&s.appearance, e)
	ecs.remove(&s.animation, e)
	ecs.remove(&s.sprite, e)
	ecs.remove(&s.layer, e)
	ecs.remove(&s.inventory, e)
	ecs.remove(&s.item, e)
}

destroy_entity :: proc(s: ^State, e: ecs.Entity) {
	if !ecs.is_alive(&s.entities, e) {
		return
	}
	detach_all_components(s, e)
	ecs.destroy_entity(&s.entities, e)
	if s.player == e {
		s.player = ecs.NIL
	}
}

// ----------------------------------------------------------------- spawning
//
// Resolve identity once at spawn, then work with plain data forever after.
// After these procs return, nothing in the simulation knows what "a player"
// is - there is only an entity that happens to have intent, movement params
// and health.

spawn :: proc(s: ^State, req: Spawn_Request) -> ecs.Entity {
	switch req.kind {
	case .Player:
		return spawn_player(s, req.position)
	case .Walker:
		return spawn_walker(s, req.position)
	case .Coin:
		return spawn_coin(s, req.position)
	}
	return ecs.NIL
}

spawn_player :: proc(s: ^State, position: Vec2) -> ecs.Entity {
	e := ecs.create_entity(&s.entities)
	ecs.add(&s.position, e, position)
	ecs.add(&s.previous_position, e, position)
	ecs.add(&s.velocity, e, Vec2{0, 0})
	ecs.add(&s.collider, e, Collider{size = {12, 20}})
	ecs.add(&s.grounded, e, Grounded{})
	ecs.add(&s.intent, e, Intent{})
	ecs.add(&s.movement, e, Movement_Params{
		move_speed     = 110,
		jump_speed     = 260,
		gravity        = 900,
		max_fall_speed = 640,
		ground_damping = 18,
		air_control    = 0.55,
	})
	ecs.add(&s.health, e, Health{current = 100, max = 100})
	ecs.add(&s.appearance, e, Appearance{texture = .Player, tint = {236, 226, 196, 255}})
	ecs.add(&s.animation, e, Animation_State{})
	ecs.add(&s.sprite, e, Sprite{})
	ecs.add(&s.layer, e, Layer{depth = 10})
	ecs.add(&s.inventory, e, Inventory{})
	// No `ai` component: the player's intent comes from the input system.
	s.player = e
	return e
}

spawn_walker :: proc(s: ^State, position: Vec2) -> ecs.Entity {
	e := ecs.create_entity(&s.entities)
	ecs.add(&s.position, e, position)
	ecs.add(&s.previous_position, e, position)
	ecs.add(&s.velocity, e, Vec2{0, 0})
	ecs.add(&s.collider, e, Collider{size = {12, 14}})
	ecs.add(&s.grounded, e, Grounded{})
	ecs.add(&s.intent, e, Intent{})
	ecs.add(&s.movement, e, Movement_Params{
		move_speed     = 42,
		jump_speed     = 200,
		gravity        = 900,
		max_fall_speed = 640,
		ground_damping = 14,
		air_control    = 0.3,
	})
	ecs.add(&s.ai, e, AI_State{behaviour = .Patrol, facing = 1})
	ecs.add(&s.health, e, Health{current = 30, max = 30})
	ecs.add(&s.appearance, e, Appearance{texture = .Creature, tint = {180, 96, 120, 255}})
	ecs.add(&s.animation, e, Animation_State{})
	ecs.add(&s.sprite, e, Sprite{})
	ecs.add(&s.layer, e, Layer{depth = 5})
	return e
}

// A coin has position, collider, appearance and an item slot. It has no
// health, so nothing can damage it; no movement params, so gravity never
// touches it. Nothing had to declare either of those facts.
spawn_coin :: proc(s: ^State, position: Vec2) -> ecs.Entity {
	e := ecs.create_entity(&s.entities)
	ecs.add(&s.position, e, position)
	ecs.add(&s.previous_position, e, position)
	ecs.add(&s.collider, e, Collider{size = {8, 8}})
	ecs.add(&s.item, e, Item_Slot{item = .Coin, count = 1})
	ecs.add(&s.appearance, e, Appearance{texture = .Item, tint = {230, 196, 84, 255}})
	ecs.add(&s.layer, e, Layer{depth = 4})
	return e
}
