package sim

import "../world"

// Two rules hold across every component type in this package.
//
// All of them are plain old data - no pointers, no dynamic arrays. That is
// what lets saving be "write the arrays out" and a dormant entity be a memcpy.
// A component holding a pointer would compile and produce a corrupt save.
//
// Absence of a component is the declaration. There is no `has_health` flag,
// because an entity with no entry in the health array is one the damage system
// never finds.

Vec2 :: [2]f32

// Shorthand for the collision systems. Not a re-export: nothing outside `sim`
// uses it.
TILE_SIZE :: world.TILE_SIZE
