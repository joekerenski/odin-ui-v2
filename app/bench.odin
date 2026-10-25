package main

// --bench: a scripted session through the three tabs, then ui.perf_report.
// The process exits with 1 when CPU or GPU p99 is over the 120 fps budget.
//
//   frames    0-299   Graph, the simulation running
//   frames  300-699   Showcase, scrolled to the bottom and back
//   frames  700-1099  Design, the panel and the showcase scrolled
//   frames 1100-1229  Showcase at 125% zoom

import ui "../ui"

BENCH_WARMUP :: 30
BENCH_FRAMES :: 1200

// Drive the session for frame `f` of the benchmark; true when it's over.
bench_step :: proc(f: int, tab: ^Tab) -> (done: bool) {
	glide :: proc(id: string, f, start, length: int) {
		// Down at 6 points a frame for half the stretch, then back up.
		half := length / 2
		k := f - start
		ui.scroll_to(id, f32(k if k < half else max(0, length - k)) * 6)
	}
	switch {
	case f < 300:
		tab^ = .Graph
	case f < 700:
		tab^ = .Showcase
		glide("Showcase", f, 300, 400)
	case f < 1100:
		tab^ = .Design
		glide("LabPanel", f, 700, 400)
		glide("Showcase", f, 700, 400)
	case f == 1100:
		tab^ = .Showcase
		ui.set_zoom(1.25)
	case:
		glide("Showcase", f, 1100, 130)
	}
	return f >= BENCH_WARMUP + BENCH_FRAMES
}
