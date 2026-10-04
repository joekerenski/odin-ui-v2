package main

// Three tabs under a top bar. Graph: nodes repel, edges pull, the panel edits
// the model. Showcase: every widget in a scrollable column (showcase.odin).
// Design: edit the look and feel and save it as a design file
// (design_lab.odin).
//
//   ./run.sh
//   ./run.sh --shot           write graph-shot.png after a short run and quit
//   ./run.sh --showcase       start on the Showcase tab
//   ./run.sh --lab            start on the Design tab
//   ./run.sh --design=soft    start with designs/soft.toml (default: console)
//   ./run.sh --theme=light    start with colors: omarchy, system, dark, or light
//   ./run.sh --raylib-log     print raylib's full log (default: errors only)
//
// Drag a node to pin it under the cursor. Link is a mode: the next node you
// click is tied to the selection. Esc quits, F toggles fullscreen, space pauses,
// Ctrl +/-/0 zooms the UI (Cmd on macOS).

import ui "../ui"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import rl "../deps/raylib"

// Embedded, so the binary runs from any directory.
FONT :: #load("../fonts/Inter-Medium.ttf")

Tab :: enum {
	Graph,
	Showcase,
	Design,
}

// In Tab order.
TAB_LABELS := []string{"Graph", "Showcase", "Design"}

main :: proc() {
	shot := false
	raylib_log := false
	tab := Tab.Graph
	start_theme: Maybe(Theme_Source)
	start_design := ""
	for a in os.args[1:] {
		if strings.has_prefix(a, "--design=") {
			start_design = a[len("--design="):]
			continue
		}
		switch a {
		case "--shot":
			shot = true
		case "--raylib-log":
			raylib_log = true
		case "--showcase":
			tab = .Showcase
		case "--lab":
			tab = .Design
		case "--theme=omarchy":
			start_theme = .Omarchy
		case "--theme=system":
			start_theme = .System
		case "--theme=dark":
			start_theme = .Dark
		case "--theme=light":
			start_theme = .Light
		}
	}

	g := Graph{}
	boot(&g)
	defer shutdown_graph(&g)

	sc := showcase_init()

	ui.init({
		title      = "odin-ui",
		width      = 1180,
		height     = 780,
		resizable  = true,
		high_dpi   = true,
		msaa_4x    = true,
		target_fps = 60,
		min_width  = 720,
		min_height = 480,
		raylib_log = raylib_log,
	})
	defer ui.shutdown()

	// Designs name it; the first font registered is also the fallback.
	ui.register_font("Inter-Medium", FONT)

	lab: Lab
	lab_init(&lab, start_design)
	defer lab_destroy(&lab)
	ui.apply_design(lab.design, nil)

	th: Theming
	theming_init(&th)
	defer theming_destroy(&th)
	if s, ok := start_theme.?; ok {
		theming_set(&th, s, fade = 0)
	}

	drag_id := -1
	frame_n := 0

	for ui.frame() {
		free_all(context.temp_allocator)
		frame_n += 1

		// While a text field has the keyboard, keys are typing: Escape
		// leaves the field instead of quitting, and F is just an F.
		if ui.key_pressed(.Escape) {
			if ui.editing() {
				ui.blur()
			} else {
				ui.request_quit()
				break
			}
		}
		// Bare keys only: Cmd+N and friends belong to the system.
		if ui.key_pressed_bare(.F) && !ui.editing() {
			ui.toggle_fullscreen()
		}
		ui.zoom_shortcuts()
		theming_update(&th)
		lab_update(&lab, &th)
		if tab == .Graph {
			graph_input(&g, &drag_id)
		} else {
			drag_id = -1
		}

		step(&g, ui.frame_dt)

		// The layout is built for this tab; a click on the tab bar switches
		// from the next frame on.
		shown := tab
		ui.begin_layout()
		if ui.root_begin("Root", true, .TopToBottom) {
			if ui.top_bar_begin() {
				ui.body("odin-ui", ui.theme.text_dim)
				tab = Tab(ui.tab_bar("Tabs", TAB_LABELS, int(tab)))
				ui.element_end()
			}
			if ui.row_begin("Body", {grow_h = true}) {
				switch shown {
				case .Graph:
					build_panel(&g)
				case .Showcase:
					build_showcase(&sc, &th)
				case .Design:
					lab_panel(&lab, &th)
					build_showcase(&sc, &th)
				}
				ui.element_end()
			}
			ui.element_end()
		}
		ui.debug_strip()
		cmds := ui.end_layout()

		ui.begin_draw()
		if shown == .Graph && ui.begin_clip("Canvas") {
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

// Keys and mouse for the Graph tab: shortcuts, node picking, dragging, linking.
@(private)
graph_input :: proc(g: ^Graph, drag_id: ^int) {
	if ui.key_pressed_bare(.Space) {
		g.paused = !g.paused
	}
	if ui.key_pressed_bare(.N) {
		sprout(g)
	}
	if ui.key_pressed_bare(.Backspace) || ui.key_pressed_bare(.Delete) {
		if g.selected >= 0 {
			delete_node(g, g.selected)
			drag_id^ = -1
		}
	}

	canvas, canvas_ok := ui.region("Canvas")
	world := [2]f32{}
	if canvas_ok {
		world = screen_to_world(canvas, ui.input.mouse_x, ui.input.mouse_y)
	}

	if drag_id^ >= 0 {
			if ui.mouse_down() {
				if idx := find_node(g, drag_id^); idx >= 0 {
				g.nodes[idx].pos = world
				dt := math.max(ui.frame_dt, 1.0 / 1000)
				g.nodes[idx].vel = {ui.input.mouse_delta_x / dt, ui.input.mouse_delta_y / dt}
			}
		} else {
			drag_id^ = -1
		}
	} else if canvas_ok && ui.hovered("Canvas") && ui.mouse_pressed() {
		hit := node_at(g, world)
		if hit >= 0 && g.linking && g.selected >= 0 && hit != g.selected {
			add_edge(g, g.selected, hit)
			g.selected = hit
		} else if hit >= 0 {
			g.selected = hit
			drag_id^ = hit
			if idx := find_node(g, hit); idx >= 0 {
				g.nodes[idx].vel = {}
			}
		} else {
			g.selected = -1
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
		ui.panel_end("Panel")
	}
	ui.canvas_begin("Canvas", ui.Color{}) // transparent: the graph is drawn under the UI
	ui.element_end()
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
			size := ui.text_draw_size(ui.theme.font_small, ui.theme.size_small)
			ts := rl.MeasureTextEx(font, label, size, 0)
			pos := [2]f32{ui.snap_px(p.x - ts.x * 0.5), ui.snap_px(p.y - ts.y * 0.5)}
			rl.DrawTextEx(font, label, pos, size, 0, ui.to_rl_color(ui.theme.text))
		}
	}
}
