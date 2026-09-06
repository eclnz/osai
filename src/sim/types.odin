package sim

import "../world"

// Package vocabulary. Every component type now lives in its group's file -
// spatial.odin, control.odin, status.odin, presentation.odin, inventory.odin -
// or, for animation, alongside the system that drives it. What is left is the
// handful of things that belong to no group.
//
// The component types share one property worth stating once: all of them are
// plain old data. No pointers, no dynamic arrays, no methods. That is what
// lets persistence be "write the arrays out", and what lets a component be
// copied into a dormant blob without a deep copy.
//
// And absence of a component *is* the declaration. There is no `has_health`
// flag anywhere, because an entity with no entry in the health array cannot be
// damaged - the damage system simply does not find it.

Vec2 :: [2]f32

// Shorthand for the collision system, which works in tile units constantly.
// Not a re-export for outside callers: nothing outside `sim` uses it.
TILE_SIZE :: world.TILE_SIZE
