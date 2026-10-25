package ui

import clay "../deps/clay"
import rlgl "../deps/raylib/rlgl"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:time"
import gl "vendor:OpenGL"

// Frame timing, measured by the frame loop itself: the app adds nothing. A
// frame is split at the calls it already makes, against a budget of 120 fps
// on any display (perf_budget_fps), where the CPU and the GPU each get 8.33 ms
// (they work side by side). F3 shows the debug strip: the last 120 frames'
// average and worst of each part, colored against the budget.
//
//   Tick    the frame wait's end to begin_layout: input, the app's own logic
//   Layout  begin_layout to end_layout: building the UI, Clay's layout
//   Draw    begin_draw to the last draw call: host drawing, render, the upload
//   CPU     the frame wait's end to the swap: all of the above
//   GPU     the frame's draw calls, from GL_TIME_ELAPSED queries read three
//           frames late, so reading them never stalls
//   Swap    end_draw's present wait and swap: mostly waiting, shown, not budgeted
//   Frame   from one frame to the next
//
// The wait for the frame's slot happens in `frame` and counts nowhere. Idle
// ticks (idle.odin) draw nothing and aren't frames here.
//
// A benchmark: perf_bench_start, then a scripted session (perf_bench_frames
// says how far it is), then perf_report, which prints the average, p50, p99
// and worst of each part and says whether CPU and GPU p99 fit the budget.

Perf_Part :: enum u8 {
	Tick,
	Layout,
	Draw,
	CPU,
	GPU,
	Swap,
	Frame,
}

// The parts held to the budget.
PERF_BUDGETED :: bit_set[Perf_Part]{.CPU, .GPU}

// Frames the strip averages over.
PERF_WINDOW :: 120

// The rate the budget is for. 120 whatever the display: a 60 Hz screen hides
// a frame that would miss on a 120 Hz one.
perf_budget_fps: f32 = 120

perf_budget_ms :: proc() -> f32 {
	return 1000 / perf_budget_fps
}

// Average and worst of the last PERF_WINDOW frames, in ms.
Perf_Stats :: struct {
	avg, worst: [Perf_Part]f32,
	frames:     int,
	gpu:        bool, // GPU timing works on this GL context
}

perf_stats :: proc() -> (s: Perf_Stats) {
	n := min(s_perf.n, PERF_WINDOW)
	s.frames = n
	s.gpu = s_perf.gpu_ok
	if n == 0 {
		return
	}
	for p in Perf_Part {
		sum: f32
		for k in 0 ..< n {
			v := s_perf.ring[p][k]
			sum += v
			s.worst[p] = max(s.worst[p], v)
		}
		s.avg[p] = sum / f32(n)
	}
	return
}

// Record every frame from `warmup` frames on, for perf_report.
perf_bench_start :: proc(warmup := 30) {
	for p in Perf_Part {
		clear(&s_perf.all[p])
	}
	s_perf.bench = true
	s_perf.bench_warmup = warmup
	s_perf.bench_frames = 0
}

// Frames run since perf_bench_start, warmup included.
perf_bench_frames :: proc() -> int {
	return s_perf.bench_frames
}

// Print the benchmark: avg, p50, p99 and worst per part. False when CPU or
// GPU p99 is over the budget.
perf_report :: proc(title: string) -> (ok: bool) {
	ok = true
	budget := perf_budget_ms()
	recorded := len(s_perf.all[.CPU])
	fmt.printfln("%s: %d frames after %d warmup, budget %.2f ms (%.0f fps)", title, recorded, s_perf.bench_warmup, budget, perf_budget_fps)
	for p in Perf_Part {
		v := s_perf.all[p][:]
		if len(v) == 0 {
			continue
		}
		slice.sort(v)
		sum: f32
		for x in v {
			sum += x
		}
		p99 := v[min(len(v) - 1, len(v) * 99 / 100)]
		verdict := ""
		if p in PERF_BUDGETED {
			verdict = "ok" if p99 <= budget else "OVER BUDGET"
			ok &&= p99 <= budget
		}
		fmt.printfln("  %-6v avg %s  p50 %s  p99 %s  max %s ms  %s", p, perf_ms(sum / f32(len(v))), perf_ms(v[len(v) / 2]), perf_ms(p99), perf_ms(v[len(v) - 1]), verdict)
	}
	if !s_perf.gpu_ok {
		fmt.println("  (no GPU timer queries on this GL context)")
	}
	return
}

// --- the strip -------------------------------------------------------------------------

@(private)
debug_strip_on := true

// Show or hide the debug strip (F3 toggles it too).
show_debug_strip :: proc(on: bool) {
	debug_strip_on = on
}

// The timing and the UI's counts, floating in the top right. Call while
// building the UI, every frame; F3 toggles it.
debug_strip :: proc() {
	if key_pressed(.F3) {
		debug_strip_on = !debug_strip_on
		request_redraw()
	}
	if !debug_strip_on {
		return
	}
	ps := perf_stats()
	st := stats()
	t := theme
	if clay.UI(clay.ID("UiDebug"))(clay.ElementDeclaration{
		layout = {
			sizing          = {width = clay.SizingFit({}), height = clay.SizingFit({})},
			layoutDirection = .TopToBottom,
			padding         = {12, 12, 8, 8},
			childGap        = 2,
		},
		backgroundColor = mix(t.bg, t.panel, 0.7), // opaque: numbers over text don't read
		cornerRadius    = clay.CornerRadiusAll(t.radius_sm),
		border          = {color = t.border, width = {1, 1, 1, 1, 0}},
		floating = {
			attachTo           = .Root,
			zIndex             = 3000,
			pointerCaptureMode = .Passthrough,
			attachment         = {element = .RightBottom, parent = .RightBottom},
			offset             = {-12, -12},
		},
	}) {
		line :: proc(s: string, color: Color) {
			text(s, theme.font_mono, theme.size_small, color)
		}
		budget := perf_budget_ms()
		line(fmt.tprintf("%d fps   budget %.2f ms (%.0f fps)", st.fps, budget, perf_budget_fps), t.text_dim)
		for p in Perf_Part {
			if p == .GPU && !ps.gpu {
				continue
			}
			color := t.text_dim
			if p in PERF_BUDGETED {
				color = t.success
				if ps.worst[p] > budget * 0.5 {
					color = t.warning
				}
				if ps.worst[p] > budget {
					color = t.danger
				}
			}
			line(fmt.tprintf("%-6v avg %s  max %s", p, perf_ms(ps.avg[p], 2), perf_ms(ps.worst[p], 2)), color)
		}
		line(fmt.tprintf("clay %d KB  %d cmds  custom %d/%d", st.clay_kb, st.cmds, st.custom, st.custom_max), t.text_dim)
		line(fmt.tprintf("zoom %d%%   F3 hide", int(math.round(st.zoom * 100))), t.text_dim)
	}
}

// Milliseconds right-aligned in a column (fmt pads numbers with zeros). Temp allocated.
@(private)
perf_ms :: proc(v: f32, decimals := 3) -> string {
	s := fmt.tprintf("%.*f", decimals, v)
	return fmt.tprintf("%*s", 4 + decimals, s)
}

// --- measuring (the frame loop calls these) --------------------------------------------

// Queries in flight: a result is read GPU_RING - 1 frames after it was issued.
@(private)
GPU_RING :: 4

@(private)
s_perf: struct {
	cur:          [Perf_Part]f32,
	ring:         [Perf_Part][PERF_WINDOW]f32,
	n:            int,
	queries:      [GPU_RING]u32,
	issued:       [GPU_RING]bool,
	gpu_ok:       bool,
	gpu_frame:    int,
	gpu_ready:    bool,
	gpu_open:     bool,
	bench:        bool,
	bench_warmup: int,
	bench_frames: int,
	all:          [Perf_Part][dynamic]f32,
	// Where the parts start.
	t_ready:      time.Tick, // the frame wait ended
	t_layout:     time.Tick,
	t_draw:       time.Tick,
	t_swap:       time.Tick,
}

// After the window exists: GL comes from raylib's context (3.3 core has
// timer queries).
@(private)
perf_setup :: proc() {
	gl.load_up_to(3, 3, proc(p: rawptr, name: cstring) {
		(cast(^rawptr)p)^ = rlgl.GetProcAddress(name)
	})
	s_perf.gpu_ok = gl.GenQueries != nil && gl.BeginQuery != nil && gl.GetQueryObjectui64v != nil
	if s_perf.gpu_ok {
		gl.GenQueries(GPU_RING, &s_perf.queries[0])
	}
}

@(private)
perf_teardown :: proc() {
	if s_perf.gpu_ok {
		gl.DeleteQueries(GPU_RING, &s_perf.queries[0])
	}
	for p in Perf_Part {
		delete(s_perf.all[p])
	}
	s_perf = {}
}

@(private)
perf_mark_ready :: proc() {
	s_perf.t_ready = time.tick_now()
	gpu := s_perf.cur[.GPU] // until a newer result is in
	s_perf.cur = {}
	s_perf.cur[.GPU] = gpu
	s_perf.cur[.Frame] = frame_dt * 1000
}

@(private)
perf_since :: proc(t: time.Tick) -> f32 {
	return f32(time.duration_milliseconds(time.tick_since(t)))
}

@(private)
perf_layout_begin :: proc() {
	s_perf.t_layout = time.tick_now()
	s_perf.cur[.Tick] = perf_since(s_perf.t_ready)
}

@(private)
perf_layout_end :: proc() {
	s_perf.cur[.Layout] = perf_since(s_perf.t_layout)
}

// begin_draw: the GPU query opens before anything is drawn.
@(private)
perf_draw_begin :: proc() {
	s_perf.t_draw = time.tick_now()
	if s_perf.gpu_ok {
		gl.BeginQuery(gl.TIME_ELAPSED, s_perf.queries[s_perf.gpu_frame % GPU_RING])
		s_perf.gpu_open = true
	}
}

// end_draw, after the last draw call and before the present wait. The
// clock is read before the query ends: on macOS, glEndQuery flushes the
// context and waits for a free command buffer when the CPU is ahead, which
// is the GPU pacing the frame, so Swap's, not the CPU's work.
@(private)
perf_draw_end :: proc() {
	s_perf.cur[.Draw] = perf_since(s_perf.t_draw)
	s_perf.cur[.CPU] = perf_since(s_perf.t_ready)
	s_perf.t_swap = time.tick_now()
	if s_perf.gpu_open {
		gl.EndQuery(gl.TIME_ELAPSED)
		s_perf.gpu_open = false
		s_perf.issued[s_perf.gpu_frame % GPU_RING] = true
	}
}

// After the swap: the GPU time from GPU_RING - 1 frames ago, if it's in, and
// the frame into the window (and the benchmark).
@(private)
perf_frame_end :: proc() {
	s_perf.cur[.Swap] = perf_since(s_perf.t_swap)
	s_perf.gpu_ready = false
	if s_perf.gpu_ok {
		old := (s_perf.gpu_frame + 1) % GPU_RING
		if s_perf.issued[old] {
			avail: i32
			gl.GetQueryObjectiv(s_perf.queries[old], gl.QUERY_RESULT_AVAILABLE, &avail)
			if avail != 0 {
				ns: u64
				gl.GetQueryObjectui64v(s_perf.queries[old], gl.QUERY_RESULT, &ns)
				s_perf.cur[.GPU] = f32(f64(ns) / 1e6)
				s_perf.gpu_ready = true
			}
		}
		s_perf.gpu_frame += 1
	}
	i := s_perf.n % PERF_WINDOW
	for p in Perf_Part {
		s_perf.ring[p][i] = s_perf.cur[p]
	}
	s_perf.n += 1
	if s_perf.bench {
		s_perf.bench_frames += 1
		if s_perf.bench_frames > s_perf.bench_warmup {
			for p in Perf_Part {
				// A GPU result not in yet is skipped, not counted as 0.
				if p == .GPU && !s_perf.gpu_ready {
					continue
				}
				append(&s_perf.all[p], s_perf.cur[p])
			}
		}
	}
}
