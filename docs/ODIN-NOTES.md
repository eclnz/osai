# Odin notes

The language features this codebase actually uses, each with the place to go
read it in context. Not a tutorial — a map, for someone who can already read C
or Go and wants to know what is different here.

## Packages are directories

A package is every `.odin` file in one directory. There are no header files and
no per-file imports of siblings: `sim/sys_drains.odin` calls `command_animation`
from `sim/sys_animation.odin` with no ceremony, because they are the same package.

Imports are paths, and the last element is the name you use:

```odin
import "../ecs"                 // -> ecs.entity_create(...)
import rl "vendor:raylib"       // renamed, because `raylib.DrawText` is a mouthful
```

Two things follow that shape the layout in [README.md](../README.md): import
cycles are illegal, so the package graph must be a DAG, and *not* importing
something is a real access-control mechanism. `sim` cannot touch
`render_position` because it does not import `render`.

`@(private)` marks a declaration package-private. `src/world/noise.odin` uses it
for `splitmix64` — the hash is an implementation detail of the noise functions.

## Parametric polymorphism

`$T` in a declaration makes it a compile-time parameter. `Sparse_Set` in
`src/ecs/sparse_set.odin` is one type per component type, monomorphised, with no
boxing and no interface dispatch:

```odin
Sparse_Set :: struct($T: typeid) {
	dense:  [dynamic]T,
	owners: [dynamic]Entity,
	sparse: [dynamic]u32,
}

add :: proc(s: ^Sparse_Set($T), e: Entity, value: T) { ... }
```

`$T` in the *procedure* is inferred from the argument, so call sites read as if
it were an ordinary function: `ecs.add(&s.position, e, Vec2{0, 0})`.

`take :: proc(r: ^Reader, $T: typeid) -> (T, bool)` in `src/serial/serial.odin`
passes the type explicitly instead — `take(r, u32)` — because there is no
argument to infer it from.

## Arrays are values, and they do arithmetic

`[2]f32` supports the arithmetic operators component-wise, which is why there is
no vector library here:

```odin
Vec2 :: [2]f32
pos += vel^ * dt                       // sim/sys_control.odin
render_position = prev + (pos - prev) * alpha   // render/render.odin
```

`Vec2 :: [2]f32` is an *alias*: it is the same type as `[2]f32` and as
`rl.Vector2`, so they interoperate with no conversion. `distinct` would make a
new type instead — raylib's `Color :: distinct [4]u8` is one, which is why the
renderer writes `rl.Color(appearance.tint)` to convert from a plain `[4]u8`.

Fixed-size arrays are values: `[CHUNK_AREA]Tile` inside `Chunk` is 1024 bytes
in the struct, not a pointer, and `a.tiles == b.tiles` compares all of it
(`tests/world_test.odin` relies on that).

## Enumerated arrays

An array can be indexed by an enum rather than an integer, and the compiler
checks that the literal covers every case. That is exactly the spec's
"definition table indexed by type ID":

```odin
tile_definitions := [Tile]Tile_Definition {
	.Empty = {...},
	.Dirt  = {...},
	...
}
```

Add a variant to `Tile` and the compiler makes you fill in the row. See
`src/world/tiles.odin` and `animation_definitions` in `src/sim/comp_animation.odin`.

`.Empty` with no prefix is an implicit enum selector: the type is known from
context, so the enum name is not repeated.

## bit_set

`Component_Flags :: bit_set[Component_Flag; u32]` in `src/sim/dormant.odin` is
a set of enum values in one `u32`, with set operators:

```odin
d.present += {.Position}          // insert
if .Health in d.present { ... }   // test
```

## Iterating with references

`for x in arr` gives copies. `for &x in arr` gives a reference you can write
through, and both forms optionally take an index:

```odin
for &anim, i in s.animation.dense {
	e := s.animation.owners[i]        // parallel arrays: same index, same entity
	anim.elapsed += dt                // writes into the array
}
```

That parallel-index pattern is the whole ECS iteration idiom here: `dense[i]` is
the component, `owners[i]` is whose it is.

## Multiple returns, `or_else`, `or_return`

Procedures return tuples, and the last value is conventionally an ok/error:

```odin
d, ok := dense_index(s, e)
```

`or_else` supplies a default and discards the flag:

```odin
opt.ticks = strconv.parse_int(...) or_else opt.ticks
return t.chunks[cc] or_else nil
```

`or_return` propagates a failure out of the current procedure, which is what
keeps `load_body` in `src/sim/save.odin` readable — thirty reads that each have
to bail on a truncated file, with no error handling visible at all:

```odin
n := take(r, u32) or_return
```

## defer

Runs at scope exit, in reverse order. Used for cleanup right next to
acquisition, so every test reads:

```odin
s: sim.State
flat_state(&s)
defer sim.state_destroy(&s)
```

## Allocators and `context`

Every procedure gets an implicit `context` carrying an allocator. `make`,
`append`, `new` and `delete` use `context.allocator` unless told otherwise.

`context.temp_allocator` is an arena you do not free individually — the frame
loop calls `free_all(context.temp_allocator)` once per frame, and anything
scratch allocated during that frame goes away. `streaming_update` uses it for
its wanted/unload/leaving lists, which are pure per-call scratch:

```odin
to_unload := make([dynamic]world.Chunk_Coord, context.temp_allocator)
```

## Labelled loops

`break` and `continue` can name a loop, which is how the collision search
escapes two nested tile loops at once:

```odin
search_x: for ty in lo.y ..= hi.y {
	for tx in lo.x ..= hi.x {
		...
		break search_x
	}
}
```

Also note the two range forms: `..<` is half-open, `..=` is inclusive.

## transmute and raw bytes

`transmute` reinterprets bits without changing them. `src/serial/serial.odin` uses it
to view any value as its bytes:

```odin
bytes := transmute(^[size_of(T)]u8)(&v)
append(&w.buf, ..bytes[:])
```

The `..` before `bytes[:]` spreads a slice into a variadic parameter.

This is only sound because every saved type is POD. That is a property of the
component types, not of the serialiser — a component holding a pointer or a
`[dynamic]` would compile here and produce a corrupt save. Worth remembering
when adding a component array.

## maps

```odin
chunks: map[Chunk_Coord]^Chunk
cc in t.chunks          // membership
cc not_in s.resident
delete_key(&t.chunks, cc)
for coord, chunk in t.chunks { ... }
```

A map key can be any comparable type, including `[2]i32`, which is why chunk
coordinates are used directly as keys.

Note the aliasing trap in `unload_chunk`: a pointer into a map's storage is
invalidated by the next insertion, so the code re-takes the pointer after
inserting rather than holding one across the write.

## Procedure groups

`os.write_entire_file` is a `proc{...}` group — several procedures under one
name, resolved by argument types. When an overload does not match, the compiler
lists the candidates, which is the usual way to discover the actual signature.

## Testing

`odin test tests` compiles the `tests` package and runs every `@(test)`
procedure, in parallel, with allocation tracking on. `testing.expect_value`
prints both sides on failure; `testing.expect` takes an optional message.

Tests import the packages under test by relative path (`import "../src/sim"`),
so the test package is an ordinary consumer of the same public API everything
else uses.

## vendor:raylib

raylib ships with the Odin distribution as `vendor:raylib`, prebuilt — there is
nothing to install and nothing to link by hand. The bindings are close to the C
API (`rl.BeginDrawing`, `rl.DrawTexturePro`), with enums where C uses ints, so
`rl.IsKeyDown(.SPACE)` rather than a `KEY_SPACE` constant.

`fmt.ctprintf` produces a temporary NUL-terminated `cstring` for the C API,
allocated in the temp allocator — hence the `free_all(context.temp_allocator)`
at the end of each frame.
