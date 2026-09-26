package main

// Spring graph. Nodes repel, edges pull, the panel edits the model.
//
//   ./run.sh
//   ./run.sh --shot     write graph-shot.png after a short run and quit
//
// Drag a node to pin it under the cursor. Link is a mode: the next node you
// click is tied to the selection. Esc quits, F toggles fullscreen, space pauses.

import ui "../ui"
import "core:fmt"
import "core:math"
import "core:os"
import rl "vendor:raylib"

FONT :: "fonts/Inter-Medium.ttf"

main :: proc() {
	shot := false
	for a in os.args[1:] {
		if a == "--shot" {
			shot = true
		}
	}

	g := Graph{}
	boot(&g)
	defer shutdown_graph(&g)

	ui.theme.gap_md = 8
	ui.theme.panel_w = 280

	ui.init({
		title      = "graph",
		width      = 1180,
		height     = 780,
		resizable  = true,
		high_dpi   = true,
		msaa_4x    = true,
		target_fps = 60,
	})
	defer ui.shutdown()

	ui.load_font(ui.theme.font_title, ui.theme.size_title, FONT)
	ui.load_font(ui.theme.font_body, ui.theme.size_body, FONT)
	ui.load_font(ui.theme.font_small, ui.theme.size_small, FONT)

	drag_id := -1
	frame_n := 0

	for ui.frame() {
		free_all(context.temp_allocator)
		frame_n += 1

		if ui.key_pressed(.Escape) {
			ui.request_quit()
			break
		}
		// Bare keys only: Cmd+N and friends belong to the system.
		if ui.key_pressed_bare(.F) {
			ui.toggle_fullscreen()
		}
		if ui.key_pressed_bare(.Space) {
			g.paused = !g.paused
		}
		if ui.key_pressed_bare(.N) {
			sprout(&g)
		}
		if ui.key_pressed_bare(.Backspace) || ui.key_pressed_bare(.Delete) {
			if g.selected >= 0 {
				delete_node(&g, g.selected)
				drag_id = -1
			}
		}

		panel, panel_ok := ui.region("Panel")
		over_ui := panel_ok && ui.mouse_in_box(panel)
		canvas, canvas_ok := ui.region("Canvas")
		world := [2]f32{}
		if canvas_ok {
			world = screen_to_world(canvas, ui.input.mouse_x, ui.input.mouse_y)
		}

		if drag_id >= 0 {
			if ui.mouse_down() {
				if idx := find_node(&g, drag_id); idx >= 0 {
					g.nodes[idx].pos = world
					dt := math.max(ui.frame_dt, 1.0 / 1000)
					g.nodes[idx].vel = {ui.input.mouse_delta_x / dt, ui.input.mouse_delta_y / dt}
				}
			} else {
				drag_id = -1
			}
		} else if !over_ui && canvas_ok && ui.mouse_pressed() {
			hit := node_at(&g, world)
			if hit >= 0 && g.linking && g.selected >= 0 && hit != g.selected {
				add_edge(&g, g.selected, hit)
				g.selected = hit
			} else if hit >= 0 {
				g.selected = hit
				drag_id = hit
				if idx := find_node(&g, hit); idx >= 0 {
					g.nodes[idx].vel = {}
				}
			} else {
				g.selected = -1
			}
		}

		step(&g, ui.frame_dt)

		ui.begin_layout()
		build_panel(&g)
		ui.debug_strip()
		cmds := ui.end_layout()

		ui.begin_draw()
		if ui.begin_clip("Canvas") {
			draw_graph(&g)
			ui.end_clip()
		}
		ui.render(&cmds)
		if shot && frame_n == 24 {
			ui.screenshot("graph-shot.png")
		}
		ui.end_draw()
		if shot && frame_n == 24 {
			break
		}
	}
}

@(private)
screen_to_world :: proc(canvas: ui.Region_Box, x, y: f32) -> [2]f32 {
	cx := canvas.x + canvas.width * 0.5
	cy := canvas.y + canvas.height * 0.5
	return {x - cx, y - cy}
}

@(private)
build_panel :: proc(g: ^Graph) {
	if ui.root_begin("Root", true) {
		if ui.panel_begin("Panel") {
			ui.title("Graph")
			ui.dim("springs, repulsion, a little gravity")
			ui.divider("div0")

			ui.section("SIM")
			g.paused = ui.toggle("pause", g.paused ? "PAUSE" : "RUNNING", g.paused)
			g.spring = ui.slider("spring", "Spring", g.spring, 0, 40, "%.1f")
			g.rest = ui.slider("rest", "Rest length", g.rest, 40, 280, "%.0f")
			g.repulsion = ui.slider("repulse", "Repulsion", g.repulsion, 0, 600_000, "%.0f")
			g.damping = ui.slider("damp", "Damping", g.damping, 0, 12, "%.1f")
			g.gravity = ui.slider("grav", "Gravity", g.gravity, 0, 6, "%.1f")

			ui.section("EDIT")
			if ui.button("add", "Add node", {accent = true}) {
				sprout(g)
			}
			g.linking = ui.toggle("link", g.linking ? "LINKING" : "LINK OFF", g.linking)
			if ui.button("del", "Delete selected") {
				if g.selected >= 0 {
					delete_node(g, g.selected)
				}
			}
			if ui.button("reset", "Reset") {
				reset(g)
			}

			ui.divider("div1")
			ui.dim(fmt.tprintf("%d nodes   %d edges", len(g.nodes), len(g.edges)))
			if g.selected >= 0 {
				ui.body(fmt.tprintf("selected %d", g.selected))
			} else {
				ui.dim("click a node")
			}
			ui.dim("N add   bksp delete   space pause   F fullscreen")
			ui.element_end()
		}
		ui.canvas_begin("Canvas", {0, 0, 0, 0})
		ui.element_end()
		ui.element_end()
	}
}

@(private)
draw_graph :: proc(g: ^Graph) {
	box, ok := ui.region("Canvas")
	if !ok {
		return
	}
	cx := box.x + box.width * 0.5
	cy := box.y + box.height * 0.5

	edge_col := ui.to_rl_color(ui.theme.border)
	for e in g.edges {
		ia := find_node(g, e.a)
		ib := find_node(g, e.b)
		if ia < 0 || ib < 0 {
			continue
		}
		a := g.nodes[ia].pos
		b := g.nodes[ib].pos
		rl.DrawLineEx({cx + a.x, cy + a.y}, {cx + b.x, cy + b.y}, 2, edge_col)
	}

	font := ui.glyph_font(ui.theme.font_small)
	for n in g.nodes {
		p := [2]f32{cx + n.pos.x, cy + n.pos.y}
		col := ui.theme.accent if n.id == g.selected else ui.theme.surface_hot
		ui.draw_circle(p.x, p.y, NODE_R, col)
		if n.id == g.selected {
			rl.DrawCircleLinesV(p, NODE_R + 4, ui.to_rl_color(ui.theme.accent_hot))
		}
		if font.glyphCount > 0 {
			label := fmt.ctprintf("%d", n.id)
			size := f32(ui.theme.size_small)
			ts := rl.MeasureTextEx(font, label, size, 0)
			pos := [2]f32{ui.snap_px(p.x - ts.x * 0.5), ui.snap_px(p.y - ts.y * 0.5)}
			rl.DrawTextEx(font, label, pos, size, 0, ui.to_rl_color(ui.theme.text))
		}
	}
}
