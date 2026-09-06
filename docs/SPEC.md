# 2D Engine Spec

Data-oriented, ECS, built on raylib. Written as a working document, not a finished design.

## Core rules

1. Entities are IDs. Nothing more.
2. Components are plain data in arrays. No methods, no behaviour.
3. Systems are functions that read arrays and write arrays.
4. Absence of a component *is* the declaration. Nothing "declares a concept it doesn't use."
5. Extensibility comes from adding a new array + a new system. Existing systems don't change because they never knew about it.
6. Resolve identity once at spawn, then work with plain data forever after.
7. Systems never call each other. They communicate through frame-scoped event queues.

## Storage model

**Sparse sets.** Each component has a dense data array plus a map from entity ID to dense index. Iterating one array is pure sequential access; iterating several together costs a lookup per extra array.

Archetype storage would remove that lookup, but adds migration complexity whose bugs look like gameplay bugs. Noted as a future migration if profiling demands it — systems are written the same way either way, so this is not a one-way door.

## Component arrays

**Spatial**
- `position` — x, y
- `previous_position` — x, y (for interpolation)
- `render_position` — x, y (derived, display-only, simulation must never read this)
- `velocity` — x, y
- `collider` — width, height
- `grounded` — flag

**Control**
- `intent` — horizontal direction (−1..1), jump_requested
- `movement_params` — jump strength, gravity multiplier, move speed (per-entity; player and creatures differ freely)
- `ai_state` — behaviour label + whatever that behaviour needs

**Life**
- `health` — current, max

**Presentation**
- `appearance` — texture ID, tint
- `animation_state` — current animation ID, elapsed time, frame index, commanded animation ID, command priority, command expiry
- `sprite` — source rectangle (written by animation, read by rendering)
- `layer` — draw depth

**Inventory**
- `inventory` — slots, each: item type ID + count

## Shared definition tables

Indexed by type ID, one entry per *type*, not per entity. Not saved — these are the game, not the state.

- `item_definitions` — name, stackable, max stack, space cost
- `animation_definitions` — frames, per-frame duration, per-frame socket transforms
- `tile_definitions` — solid, hazard amount
- `texture_table` — loaded GPU textures

## World storage

Terrain is **not** entities. Flat array of tile type IDs indexed by grid position, chunked into fixed-size blocks. Collision against terrain is arithmetic: divide position by tile size, look up cell.

Free-standing obstacles (moving platforms, doors) **are** entities with position, collider, and whatever else they need.

Do not make tiles entities for the sake of uniformity.

## Event queues

Frame-scoped arrays. Appended by many systems, drained by exactly one, then cleared.

- `damage_events` — target ID, amount
- `pickup_events` — entity ID, item type ID, count
- `spawn_requests`
- `sound_requests`

Rule: a queue is drained *after* everything that can append to it.

## Frame structure

**Per frame (variable rate)**
0. Streaming — update active region, load/unload chunks, insert/remove entities from component arrays, rebuild spatial grid
1. Input — reads devices → writes `intent` for the player

**Fixed timestep, repeated until caught up (cap the catch-up count)**
2. AI — reads world state → writes `intent` for everything else
3. Movement — reads intent, movement_params, grounded → writes velocity
4. Integration — copies position→previous_position, then velocity → position
5. Collision — entity vs terrain, then entity vs entity → writes grounded, corrects position, appends to queues
6. Drain queues in fixed order — damage, pickups, spawns
7. Consequences — death check, state changes, animation commands

**Per frame again**
8. Animation — resolves command vs derivation, advances frames → writes sprite
9. Interpolation — previous + current + accumulator fraction → render_position
10. Rendering — reads only. Sort by layer, then by texture. Terrain drawn as batched chunk quads.

AI sits inside the fixed step so that a seed fully reproduces a run. Input stays outside because it's tied to real frames; the fixed step just reads whatever `intent` currently holds. Queues drain once per fixed step, so damage applies at a consistent simulated rate rather than a frame-rate-dependent one.

**Streaming is residency, not filtering.** Systems never iterate a list of active IDs — that would be an ID lookup per entity per system. Instead, entities leaving the active region are serialised into their chunk and removed from the component arrays; entities entering are inserted. Everything present in the arrays is active by definition, so systems iterate with no filtering. Cost lands at chunk boundaries, which are rare; iteration happens every step. Reuses swap-and-pop, the free list, and the chunk dirty flag.

## Animation resolution

Animation is derived where it can be and commanded where it can't.

- **Derived** (lowest priority): idle, run, jump — inferred from velocity and grounded. Nothing has to tell the animation system anything.
- **Commanded**: attack, hurt, death — not visible in movement data, so systems write a commanded animation ID plus a priority into `animation_state`. The damage system writes hurt; an attack system writes attack.
- **Rule**: if an unexpired command outranks the derived animation, play it; otherwise fall back to derivation.
- Commands expire on animation completion or after a set duration. Priority is what stops the run derivation stomping a hurt animation on the next frame.

This is still just fields in an array. A system writing an animation command is the same shape as it writing to health.

## Entity lifecycle

- Free list of unused slots. Destroy pushes, create pops, grow only when empty.
- Generation counter per slot, incremented on reuse. References store (index, generation); mismatch means the target is gone.
- Component arrays stay packed via swap-and-pop. Order is meaningless, so this is safe.
- Free list and generations operate on entity slots. Swap-and-pop operates inside component arrays. Different levels, both needed.

## Persistence

State is already flat arrays, so saving is writing them out.

- Save: dirty chunks only (full snapshot per chunk, not diffs — robustness over size)
- Save: entity IDs and generations, all component arrays, inventory contents
- Don't save: definition tables, render_position, event queues
- Version number in the file, because new component arrays will break old saves
- Untouched chunks regenerate from seed
- Offline progress (growth, smelting) = store a timestamp, compute on chunk reload. Never simulate away from the player.

## Procedural generation

Not a system. Runs once, outputs a tile array and spawn requests, then it's gone.

Ordered passes: layout → terrain detail → populate → validate.

Everything takes a seed. Same seed, identical level.

Generation output is validated against declared constraints; invalid output is rejected or repaired. **What the constraints are is a gameplay decision, deliberately unspecified.** Reachability is one candidate and stops being meaningful if terrain is destructible.

## Deliberately unresolved

Not oversights — decisions that shouldn't be made yet.

- Inventory capacity model, organisation model, and full-behaviour
- Whether combat exists
- Which creature types exist
- Generation constraint set
- UI, which will not be ECS and stays walled off from simulation

---

# Decisions made

Recorded because each of these was a real fork, and the reasoning matters more than the answer.

**Storage model — sparse sets.** Component arrays are not automatically aligned; if each does its own swap-and-pop, entity 5 lands at different indices in different arrays. Alignment has to be bought, either with archetypes or with per-array index maps. Sparse sets chosen: most of the performance win comes from data being in arrays at all, and archetype migration bugs masquerade as gameplay bugs. Revisit only if profiling demands it.

**Streaming — residency, not filtering.** An active-ID list would mean a lookup per entity per system, contradicting the whole point of packed arrays. Entities move in and out of the arrays themselves instead.

**Animation — derived with commanded override.** Pure derivation from velocity and grounded covers idle/run/jump and cannot express attack, hurt, or death. Commands plus priority added, derivation kept as fallback.

**Timestep — AI inside the fixed step.** Costs a little on slow frames, buys full reproducibility from a seed. Worth it for a roguelike. Input stays outside; queues drain once per fixed step.

**Health — no guarantee.** There is no "every character declares a health concept." There is a health array. Entities in it can be damaged; entities not in it are invulnerable. No flags, no nulls, no declarations.

---

# Next unmade decisions

- Whether `intent` is one component or several (a knockback source and an AI source writing the same field will fight; may need layered intent with priority, same shape as animation)
- What happens to an in-flight projectile whose target streams out of the active region
- Whether collision correction belongs in the collision system or a separate resolution pass
