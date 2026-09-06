package render

import "../ecs"
import "../sim"
import "../world"
import "core:slice"
import rl "vendor:raylib"

// The renderer reads. It does not write to any simulation array.
//
// `render_position` lives in this package rather than in `sim.State`, which
// is the spec's "simulation must never read this" turned into something the
// compiler enforces: `sim` does not import `render`, so no system can reach
// the interpolated position even by accident.

Renderer :: struct {
	render_position: ecs.Sparse_Set(sim.Vec2),
	textures:        [sim.Texture_Id]rl.Texture2D,
	camera:          rl.Camera2D,
	draw_list:       [dynamic]Draw_Item,
}

// Sprite sheet layout. This lives here and not in `sim`: the simulation says
// which animation is playing and which frame it is on, and where that lands in
// a texture is entirely the renderer's business.
FRAME_W :: 16
FRAME_H :: 24

// Sorted by layer, then by texture: layer is correctness, texture is the
// batching key a real sprite renderer would group on.
Draw_Item :: struct {
	depth:    i16,
	texture:  sim.Texture_Id,
	position: sim.Vec2,
	size:     sim.Vec2,
	// Row and frame index into the sheet, not pixels.
	animated: bool,
	row:      int,
	frame:    int,
	flip_x:   bool,
	tint:     rl.Color,
}

@(private)
source_rect :: proc(item: Draw_Item) -> rl.Rectangle {
	// A negative width is how raylib mirrors a source region.
	w := f32(FRAME_W)
	return rl.Rectangle {
		f32(item.frame * FRAME_W),
		f32(item.row * FRAME_H),
		item.flip_x ? -w : w,
		f32(FRAME_H),
	}
}

renderer_init :: proc(r: ^Renderer, zoom: f32 = 2.5) {
	r.camera = rl.Camera2D {
		zoom   = zoom,
		offset = {f32(rl.GetScreenWidth()) * 0.5, f32(rl.GetScreenHeight()) * 0.5},
	}
}

renderer_destroy :: proc(r: ^Renderer) {
	ecs.set_destroy(&r.render_position)
	delete(r.draw_list)
	for texture in r.textures {
		if texture.id != 0 {
			rl.UnloadTexture(texture)
		}
	}
	r^ = {}
}

// Interpolation - previous + current + the accumulator fraction. Purely
// display-only: run it once per rendered frame, after the fixed steps.
interpolate :: proc(r: ^Renderer, s: ^sim.State, alpha: f32) {
	// Rebuilt from scratch each frame, so entities that were destroyed or
	// streamed out simply do not reappear. Nothing has to remove them.
	ecs.set_clear(&r.render_position)

	for pos, i in s.spatial.position.dense {
		e := s.spatial.position.owners[i]
		prev := ecs.get_or(&s.spatial.previous_position, e, pos)
		ecs.add(&r.render_position, e, prev + (pos - prev) * alpha)
	}
}

follow :: proc(r: ^Renderer, s: ^sim.State, smoothing: f32 = 1) {
	target := ecs.get_or(&r.render_position, s.player, sim.Vec2{})
	if smoothing >= 1 {
		r.camera.target = target
	} else {
		r.camera.target += (target - r.camera.target) * smoothing
	}
	r.camera.offset = {f32(rl.GetScreenWidth()) * 0.5, f32(rl.GetScreenHeight()) * 0.5}
}

BACKGROUND :: rl.Color{22, 24, 32, 255}

draw :: proc(r: ^Renderer, s: ^sim.State) {
	rl.BeginDrawing()
	rl.ClearBackground(BACKGROUND)

	rl.BeginMode2D(r.camera)
	draw_terrain(r, s)
	draw_entities(r, s)
	rl.EndMode2D()
}

// Terrain is drawn straight from the tile arrays, one quad per visible tile.
// The spec calls for batched chunk quads - one mesh per chunk, rebuilt when
// the chunk is edited. Not built yet; this is the version that is obviously
// correct and obviously slower.
draw_terrain :: proc(r: ^Renderer, s: ^sim.State) {
	view := visible_world_rect(r)
	lo := world.tile_coord_of_world({view.x, view.y})
	hi := world.tile_coord_of_world({view.x + view.width, view.y + view.height})

	for ty in lo.y ..= hi.y {
		for tx in lo.x ..= hi.x {
			tile := world.tile_at(&s.terrain, {tx, ty})
			if tile == .Empty {
				continue
			}
			def := world.tile_definitions[tile]
			rl.DrawRectangle(
				tx * world.TILE_SIZE,
				ty * world.TILE_SIZE,
				world.TILE_SIZE,
				world.TILE_SIZE,
				rl.Color(def.tint),
			)
		}
	}
}

draw_entities :: proc(r: ^Renderer, s: ^sim.State) {
	clear(&r.draw_list)

	for pos, i in r.render_position.dense {
		e := r.render_position.owners[i]

		appearance := ecs.get(&s.presentation.appearance, e)
		if appearance == nil {
			continue // nothing to draw is not an error
		}
		collider := ecs.get_or(&s.spatial.collider, e, sim.Collider{size = {8, 8}})
		anim := ecs.get(&s.presentation.animation, e)
		facing := ecs.get_or(&s.spatial.facing, e, sim.Facing(1))

		append(&r.draw_list, Draw_Item {
			depth    = ecs.get_or(&s.presentation.layer, e, sim.Layer{}).depth,
			texture  = appearance.texture,
			position = pos,
			size     = collider.size,
			animated = anim != nil,
			row      = anim != nil ? int(anim.current) : 0,
			frame    = anim != nil ? anim.frame : 0,
			flip_x   = facing < 0,
			tint     = rl.Color(appearance.tint),
		})
	}

	slice.sort_by(r.draw_list[:], proc(a, b: Draw_Item) -> bool {
		if a.depth != b.depth {
			return a.depth < b.depth
		}
		return a.texture < b.texture
	})

	for item in r.draw_list {
		texture := r.textures[item.texture]
		if texture.id == 0 {
			draw_placeholder(item)
			continue
		}
		dest := rl.Rectangle{item.position.x, item.position.y, item.size.x, item.size.y}
		rl.DrawTexturePro(texture, source_rect(item), dest, {0, 0}, 0, item.tint)
	}
}

// No art yet. Rather than draw nothing, draw the body box plus a marker for
// the current animation frame and facing, so that the animation system is
// visible without a single png in the repository.
@(private)
draw_placeholder :: proc(item: Draw_Item) {
	// `sim.Vec2` and `rl.Vector2` are both aliases of `[2]f32`, so they are
	// the same type and pass straight through.
	rl.DrawRectangleV(item.position, item.size, item.tint)

	if !item.animated {
		return
	}

	marker_x := i32(item.position.x) + (item.flip_x ? i32(item.size.x) - 3 : 1)
	rl.DrawRectangle(marker_x, i32(item.position.y) + 1, 2, 2 + i32(item.frame), {20, 20, 24, 255})
	rl.DrawRectangle(i32(item.position.x) + 1, i32(item.position.y + item.size.y) - 3, 2 + i32(item.row), 2, {20, 20, 24, 255})
}

visible_world_rect :: proc(r: ^Renderer) -> rl.Rectangle {
	top_left := rl.GetScreenToWorld2D({0, 0}, r.camera)
	bottom_right := rl.GetScreenToWorld2D(
		{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())},
		r.camera,
	)
	return rl.Rectangle {
		x = top_left.x,
		y = top_left.y,
		width = bottom_right.x - top_left.x,
		height = bottom_right.y - top_left.y,
	}
}
