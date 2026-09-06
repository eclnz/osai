package render

import "../ecs"
import "../sim"
import "core:fmt"
import rl "vendor:raylib"

// UI is not ECS and stays walled off from the simulation. This is the
// smallest version of that: it reads state, draws text, and owns nothing.

draw_debug :: proc(r: ^Renderer, s: ^sim.State, alpha: f32, steps: int) {
	health := ecs.get(&s.health, s.player)
	inv := ecs.get(&s.inventory, s.player)

	coins := 0
	if inv != nil {
		for slot in inv.slots {
			if slot.item == .Coin {
				coins += int(slot.count)
			}
		}
	}

	pos := ecs.get_or(&s.position, s.player, sim.Vec2{})

	lines := [?]string {
		fmt.tprintf("%v fps   alpha %.2f   steps %v", rl.GetFPS(), alpha, steps),
		fmt.tprintf("tick %v   entities %v   chunks %v", s.tick, s.entities.live_count, len(s.terrain.chunks)),
		fmt.tprintf("resident %v   dormant chunks %v", len(s.resident), len(s.dormant)),
		fmt.tprintf("player %.0f, %.0f   hp %.0f   coins %v",
			pos.x, pos.y, health != nil ? health.current : 0, coins),
		"arrows/wasd move, space jump, F5 save, F9 load, R respawn",
	}

	rl.DrawRectangle(0, 0, 420, i32(len(lines)) * 18 + 12, {0, 0, 0, 150})
	for line, i in lines {
		rl.DrawText(fmt.ctprintf("%s", line), 10, i32(i) * 18 + 8, 14, {220, 224, 232, 255})
	}
}
