package sim

import "../ecs"
import "../world"

// Streaming is residency, not filtering.
//
// Systems never iterate a list of active IDs - that would be an ID lookup per
// entity per system, which is the thing packed arrays exist to avoid. Instead
// an entity that leaves the active region is copied out of the component
// arrays into a blob attached to its chunk, and removed. Everything still in
// the arrays is active by definition.
//
// The entity's *slot* is not freed, so handles held elsewhere stay valid and
// keep pointing at the same entity when it streams back in. `ecs.is_alive`
// answers "does this entity exist", not "is it resident".

Component_Flag :: enum u8 {
	Position,
	Previous_Position,
	Velocity,
	Collider,
	Grounded,
	Intent,
	Movement,
	AI,
	Health,
	Appearance,
	Animation,
	Sprite,
	Layer,
	Inventory,
	Item,
}

Component_Flags :: bit_set[Component_Flag;u32]

// A whole entity as plain data. Every field is POD, so this is one memcpy
// away from being a save file record - which is exactly what save.odin does
// with it.
Dormant_Entity :: struct {
	entity:            ecs.Entity,
	present:           Component_Flags,
	position:          Vec2,
	previous_position: Vec2,
	velocity:          Vec2,
	collider:          Collider,
	grounded:          Grounded,
	intent:            Intent,
	movement:          Movement_Params,
	ai:                AI_State,
	health:            Health,
	appearance:        Appearance,
	animation:         Animation_State,
	sprite:            Sprite,
	layer:             Layer,
	inventory:         Inventory,
	item:              Item_Slot,
}

// Second of the two places that enumerate every component array (the other is
// `detach_all_components`). Adding an array means touching both.
capture_entity :: proc(s: ^State, e: ecs.Entity) -> Dormant_Entity {
	d := Dormant_Entity {
		entity = e,
	}
	if v := ecs.get(&s.position, e); v != nil {d.position = v^;d.present += {.Position}}
	if v := ecs.get(&s.previous_position, e); v != nil {d.previous_position = v^;d.present += {.Previous_Position}}
	if v := ecs.get(&s.velocity, e); v != nil {d.velocity = v^;d.present += {.Velocity}}
	if v := ecs.get(&s.collider, e); v != nil {d.collider = v^;d.present += {.Collider}}
	if v := ecs.get(&s.grounded, e); v != nil {d.grounded = v^;d.present += {.Grounded}}
	if v := ecs.get(&s.intent, e); v != nil {d.intent = v^;d.present += {.Intent}}
	if v := ecs.get(&s.movement, e); v != nil {d.movement = v^;d.present += {.Movement}}
	if v := ecs.get(&s.ai, e); v != nil {d.ai = v^;d.present += {.AI}}
	if v := ecs.get(&s.health, e); v != nil {d.health = v^;d.present += {.Health}}
	if v := ecs.get(&s.appearance, e); v != nil {d.appearance = v^;d.present += {.Appearance}}
	if v := ecs.get(&s.animation, e); v != nil {d.animation = v^;d.present += {.Animation}}
	if v := ecs.get(&s.sprite, e); v != nil {d.sprite = v^;d.present += {.Sprite}}
	if v := ecs.get(&s.layer, e); v != nil {d.layer = v^;d.present += {.Layer}}
	if v := ecs.get(&s.inventory, e); v != nil {d.inventory = v^;d.present += {.Inventory}}
	if v := ecs.get(&s.item, e); v != nil {d.item = v^;d.present += {.Item}}
	return d
}

restore_entity :: proc(s: ^State, d: Dormant_Entity) {
	e := d.entity
	if .Position in d.present {ecs.add(&s.position, e, d.position)}
	if .Previous_Position in d.present {ecs.add(&s.previous_position, e, d.previous_position)}
	if .Velocity in d.present {ecs.add(&s.velocity, e, d.velocity)}
	if .Collider in d.present {ecs.add(&s.collider, e, d.collider)}
	if .Grounded in d.present {ecs.add(&s.grounded, e, d.grounded)}
	if .Intent in d.present {ecs.add(&s.intent, e, d.intent)}
	if .Movement in d.present {ecs.add(&s.movement, e, d.movement)}
	if .AI in d.present {ecs.add(&s.ai, e, d.ai)}
	if .Health in d.present {ecs.add(&s.health, e, d.health)}
	if .Appearance in d.present {ecs.add(&s.appearance, e, d.appearance)}
	if .Animation in d.present {ecs.add(&s.animation, e, d.animation)}
	if .Sprite in d.present {ecs.add(&s.sprite, e, d.sprite)}
	if .Layer in d.present {ecs.add(&s.layer, e, d.layer)}
	if .Inventory in d.present {ecs.add(&s.inventory, e, d.inventory)}
	if .Item in d.present {ecs.add(&s.item, e, d.item)}
}

// How many chunks either side of the centre stay resident.
STREAM_RADIUS :: 2

// Step 0 of the frame. Cost lands at chunk boundaries, which are rare;
// iteration happens every step.
streaming_update :: proc(s: ^State, center: Vec2, radius := STREAM_RADIUS) {
	center_chunk := world.chunk_coord_of_world(center)

	wanted := make(map[world.Chunk_Coord]bool, context.temp_allocator)
	for dy in -i32(radius) ..= i32(radius) {
		for dx in -i32(radius) ..= i32(radius) {
			wanted[center_chunk + {dx, dy}] = true
		}
	}

	// Unload first, so an entity that has walked from one chunk to another
	// is not captured and immediately re-captured.
	to_unload := make([dynamic]world.Chunk_Coord, context.temp_allocator)
	for cc in s.resident {
		if cc not_in wanted {
			append(&to_unload, cc)
		}
	}
	for cc in to_unload {
		unload_chunk(s, cc)
	}

	for cc in wanted {
		if cc not_in s.resident {
			load_chunk(s, cc)
		}
	}
}

load_chunk :: proc(s: ^State, cc: world.Chunk_Coord) {
	if cc in s.resident {
		return
	}

	if !world.is_loaded(&s.terrain, cc) {
		// Untouched chunks regenerate from the seed; only edited ones are
		// carried around (and, later, written to disk).
		world.insert_chunk(&s.terrain, world.generate_chunk(s.seed, cc))
	}

	// Generation runs again on every reload; population does not. The
	// entities it produced the first time are dormant, not gone, and are
	// restored below.
	if cc not_in s.populated {
		s.populated[cc] = true
		chunk := world.get_chunk(&s.terrain, cc)
		requests := make([dynamic]world.Spawn_Request, context.temp_allocator)
		world.populate_chunk(s.seed, chunk, &requests)
		world.validate_spawns(&s.terrain, &requests, nil)
		for req in requests {
			spawn(s, req)
		}
	}

	// Entities that were resident here before are woken exactly as they were.
	if dormant, ok := s.dormant[cc]; ok {
		for d in dormant {
			restore_entity(s, d)
		}
		delete(dormant)
		delete_key(&s.dormant, cc)
	}

	s.resident[cc] = true
}

unload_chunk :: proc(s: ^State, cc: world.Chunk_Coord) {
	if cc not_in s.resident {
		return
	}

	// Collect first: capturing mutates the arrays we are iterating.
	leaving := make([dynamic]ecs.Entity, context.temp_allocator)
	for p, i in s.position.dense {
		if world.chunk_coord_of_world(p) == cc {
			e := s.position.owners[i]
			// The player is never streamed out from under the camera.
			if e == s.player {
				continue
			}
			append(&leaving, e)
		}
	}

	if len(leaving) > 0 {
		list, ok := &s.dormant[cc]
		if !ok {
			s.dormant[cc] = make([dynamic]Dormant_Entity)
			list = &s.dormant[cc]
		}
		for e in leaving {
			append(list, capture_entity(s, e))
			detach_all_components(s, e)
		}
	}

	// A chunk nobody has edited can be thrown away and regenerated; an edited
	// one has to be kept (in memory here, on disk once saving is wired to
	// unload).
	if chunk := world.get_chunk(&s.terrain, cc); chunk != nil && !chunk.dirty {
		world.remove_chunk(&s.terrain, cc)
		free(chunk)
	}

	delete_key(&s.resident, cc)
}
