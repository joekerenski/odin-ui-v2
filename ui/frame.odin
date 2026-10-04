package ui

import clay "../deps/clay"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:time"
import rl "../deps/raylib"
import rlgl "../deps/raylib/rlgl"

Region_Box :: clay.BoundingBox

// The window, the frame loop and Clay's lifecycle. Zoom, clipboard and cursor are in
// window.odin, font slots and measuring in fonts.odin, polling input in input.odin.
//
// The app owns the loop:
//
//   ui.init(desc)
//   ui.load_font(...)
//   for ui.frame() {
//       ui.begin_layout()
//       // widgets
//       cmds := ui.end_layout()
//       ui.begin_draw()
//       // host drawing (raylib), clipped to a region if you want
//       ui.render(&cmds)
//       ui.end_draw()
//   }
//   ui.shutdown()
//
// On macOS `frame` waits for the frame's slot, then polls input, so what the
// frame draws is as fresh as the wait allows. Present stays unsynced (swap
// interval 0); the view's display link is the clock. Fullscreen on an
// adaptive-refresh screen runs on a deadline grid instead, with a second wait
// in `end_draw` that holds the swap for its slot. See macos_darwin.odin.
//
// On Wayland the clock is the surface's frame callback, the same shape: swap
// interval 0, `frame` waits for the callback and then polls. See
// wayland_linux.odin. Under X11 it is raylib's loop with vsync.

Window_Desc :: struct {
	title:      cstring,
	width:      i32,
	height:     i32,
	resizable:  bool,
	high_dpi:   bool,
	msaa_4x:    bool,
	target_fps: i32, // 0 = the display's refresh
	// Smallest window, in points. Zooming in also stops where the layout
	// would get smaller than this.
	min_width:  i32,
	min_height: i32,
	// raylib's own log: every file load, texture upload and missing glyph.
	// Off, only its errors print.
	raylib_log: bool,
	// Seconds of quiet (no input, nothing moving, no request_redraw) after which
	// frames stop until something happens; 0 draws every frame. See idle.odin.
	idle_after: f32,
}

quit_requested: bool

request_quit :: proc() {
	quit_requested = true
}

frame_dt: f32
busy_dt: f32
screen_w: f32
screen_h: f32

@(private)
frame_start: time.Time

@(private)
target_fps: i32

@(private)
clay_memory: []u8

@(private)
last_cmd_count: int

@(private)
shown_fps: i32

@(private)
fps_acc: f32

@(private)
fps_frames: int

@(private)
shapes_tex: rl.Texture2D


// Pixels per point the glyph cache holds (display scale * zoom).
@(private)
loaded_scale: f32

init :: proc(desc: Window_Desc) {
	target_fps = desc.target_fps
	quit_requested = false
	s_idle_after = desc.idle_after
	s_idle_skipped = false

	flags: rl.ConfigFlags
	if desc.resizable do flags += {.WINDOW_RESIZABLE}
	if desc.high_dpi do flags += {.WINDOW_HIGHDPI}
	if desc.msaa_4x do flags += {.MSAA_4X_HINT}
	// macOS GL swap interval does not track ProMotion and falls apart when the
	// window is occluded. The display link in macos_darwin.odin is the clock.
	when ODIN_OS != .Darwin {
		flags += {.VSYNC_HINT}
	}
	rl.SetTraceLogLevel(.ALL if desc.raylib_log else .ERROR)
	rl.SetConfigFlags(flags)
	rl.InitWindow(desc.width, desc.height, desc.title)
	rl.SetExitKey(rl.KeyboardKey.KEY_NULL)
	min_size = {f32(desc.min_width), f32(desc.min_height)}
	if desc.min_width > 0 || desc.min_height > 0 {
		rl.SetWindowMinSize(desc.min_width, desc.min_height)
	}
	// UI fills are triangles that sample this texel; raylib's own shape calls
	// use it too.
	white := rl.GenImageColor(1, 1, rl.WHITE)
	shapes_tex = rl.LoadTextureFromImage(white)
	rl.UnloadImage(white)
	rl.SetShapesTexture(shapes_tex, {0, 0, 1, 1})

	when ODIN_OS == .Darwin {
		darwin_start()
	} else when ODIN_OS == .Linux {
		wayland_start()
	}

	zoom, pending_zoom = 1, 1
	screen_w = f32(rl.GetScreenWidth())
	screen_h = f32(rl.GetScreenHeight())
	frame_dt = 1.0 / 60.0
	loaded_scale = raster_scale()

	input = {}

	clay_setup(desc)
	reset_styles()
	custom_setup()
}

shutdown :: proc() {
	when ODIN_OS == .Darwin {
		darwin_stop()
	} else when ODIN_OS == .Linux {
		wayland_stop()
	}
	for &f in fonts {
		delete(f.path)
	}
	delete(fonts)
	fonts = nil
	glyphs_teardown()
	custom_teardown()
	idle_teardown()
	anim_teardown()
	design_teardown()
	delete(clay_memory)
	clay_memory = nil
	if shapes_tex.id != 0 {
		rl.UnloadTexture(shapes_tex)
	}
	rl.CloseWindow()
}

// Poll, pace, and report whether the window is still open.
// Call once per frame before building the UI. With idle (Window_Desc.idle_after), it waits
// here, tick by tick, while nothing would change on screen (see idle.odin).
frame :: proc() -> bool {
	for {
		frame_wait()
		if quit_requested || rl.WindowShouldClose() {
			return false
		}
		zoom = fit_zoom(pending_zoom)
		screen_w = f32(rl.GetScreenWidth()) / zoom
		screen_h = f32(rl.GetScreenHeight()) / zoom
		poll_input()
		if !idle_skip() {
			break
		}
	}

	theme_tick(frame_dt)
	anim_tick()

	// A new display scale (moved to another screen) or zoom draws text at
	// new pixel sizes: the glyphs at the old ones go, and Clay re-measures.
	scale := raster_scale()
	if math.abs(scale - loaded_scale) > 0.001 {
		loaded_scale = scale
		glyph_cache_clear()
		s_text_cache_full = true
	}

	// One-frame rate until the first half-second average exists.
	if shown_fps == 0 && frame_dt > 0 {
		shown_fps = i32(math.round(1.0 / frame_dt))
	}
	fps_acc += frame_dt
	fps_frames += 1
	if fps_acc >= 0.5 {
		shown_fps = i32(math.round(f32(fps_frames) / fps_acc))
		fps_acc = 0
		fps_frames = 0
	}

	return true
}

// Waits for the frame's slot and polls the window's events.
@(private)
frame_wait :: proc() {
	when ODIN_OS == .Darwin {
		darwin_pace()
		frame_start = time.now()
		rl.PollInputEvents()
	} else when ODIN_OS == .Linux {
		if wayland_active() {
			// Idle, no frame callback comes (nothing was committed): the wait gives up after
			// 100 ms, so input is looked at ten times a second.
			wayland_pace()
			frame_start = time.now()
			rl.PollInputEvents()
		} else {
			raylib_wait()
		}
	} else {
		raylib_wait()
	}
}

// raylib's own loop (X11, Windows): EndDrawing waits and polls; an idle tick, which doesn't
// draw, sleeps a 60 Hz tick and polls itself.
@(private)
raylib_wait :: proc() {
	if s_idle_skipped {
		time.sleep(time.Second / 60)
		rl.PollInputEvents()
		frame_dt = 1.0 / 60.0
	} else {
		frame_dt = rl.GetFrameTime()
		if frame_dt <= 0 {
			frame_dt = 1.0 / 60.0
		}
	}
	frame_start = time.now()
}

fps :: proc() -> i32 {
	return shown_fps
}

@(private)
clay_error :: proc "c" (data: clay.ErrorData) {
	context = runtime.default_context()
	if data.errorType == .TextMeasurementCapacityExceeded {
		// begin_layout empties the cache; only this frame's text goes unmeasured.
		s_text_cache_full = true
		return
	}
	fmt.eprintln("clay:", data.errorType, string(data.errorText.chars[:data.errorText.length]))
}

// Clay caches the width of every text it measured, and drops a stale entry only when a
// lookup happens to pass it. Text that changes every frame (a reply streaming in) adds an entry
// per frame, so stale ones pile up until the cache is full and text stops being measured. So the
// cache is big, emptied every TEXT_CACHE_FRAMES frames (re-measuring what's on screen once), and
// emptied at once if it fills up anyway.
@(private)
TEXT_CACHE_WORDS :: 1 << 16

@(private)
TEXT_CACHE_FRAMES :: 120

@(private)
s_text_cache_full: bool

@(private)
s_text_cache_age: int

@(private)
clay_setup :: proc(desc: Window_Desc) {
	// Before Initialize: the cache's arrays are sized then.
	clay.SetMaxMeasureTextCacheWordCount(TEXT_CACHE_WORDS)
	min_mem := clay.MinMemorySize()
	clay_memory = make([]u8, int(min_mem))
	arena := clay.CreateArenaWithCapacityAndMemory(c.size_t(min_mem), &clay_memory[0])
	clay.Initialize(arena, {f32(desc.width), f32(desc.height)}, {handler = clay_error})
	clay.SetMeasureTextFunction(measure_text, nil)
}

begin_layout :: proc() {
	custom_begin_frame()
	s_text_cache_age += 1
	if s_text_cache_full || s_text_cache_age >= TEXT_CACHE_FRAMES {
		clay.ResetMeasureTextCache()
		s_text_cache_full, s_text_cache_age = false, 0
	}
	clay.SetLayoutDimensions({screen_w, screen_h})
	clay.SetPointerState({input.mouse_x, input.mouse_y}, mouse_down(.Left))
	idle_begin_frame()
	restore := scroll_before_wheel()
	clay.UpdateScrollContainers(false, {input.wheel_x, input.wheel_y}, frame_dt)
	scroll_after_wheel(restore)
	clay.BeginLayout()
}

end_layout :: proc() -> clay.ClayArray(clay.RenderCommand) {
	cmds := clay.EndLayout(frame_dt)
	last_cmd_count = int(cmds.length)
	if s_cursor_want != s_cursor_set {
		s_cursor_set = s_cursor_want
		switch s_cursor_set {
		case .Arrow:
			rl.SetMouseCursor(.DEFAULT)
		case .Text:
			rl.SetMouseCursor(.IBEAM)
		case .Hand:
			rl.SetMouseCursor(.POINTING_HAND)
		}
	}
	s_cursor_want = .Arrow
	return cmds
}

// Everything drawn until end_draw, UI and host alike, is in layout units:
// the zoom is a scale on rlgl's matrix stack.
begin_draw :: proc() {
	rl.BeginDrawing()
	rl.ClearBackground(to_rl_color(theme.bg))
	rlgl.PushMatrix()
	rlgl.Scalef(zoom, zoom, 1)
}

end_draw :: proc() {
	// Flush first so a present wait is followed by nothing but the swap.
	rlgl.DrawRenderBatchActive()
	rlgl.PopMatrix()
	busy := time.since(frame_start)
	when ODIN_OS == .Darwin {
		darwin_present_wait()
		// Not EndDrawing: it polls input right after the swap, and a second
		// poll in `frame` would eat raylib's key-press edges.
		swap_start := time.now()
		rl.SwapScreenBuffer()
	} else when ODIN_OS == .Linux {
		swap_start := time.now()
		if wayland_active() {
			// Same reason as macOS: `frame` polls after the wait.
			wayland_request_frame()
			rl.SwapScreenBuffer()
		} else {
			rl.EndDrawing()
		}
	} else {
		swap_start := time.now()
		rl.EndDrawing()
	}
	busy_dt = f32(time.duration_seconds(busy + time.since(swap_start)))
}

// Write the back buffer to a PNG at framebuffer resolution. Call after
// drawing, before end_draw. raylib's TakeScreenshot scales by the DPI a second
// time on macOS: a 2x image with the frame in one corner.
screenshot :: proc(path: cstring) -> bool {
	rlgl.DrawRenderBatchActive()
	w, h := framebuffer_size()
	pixels := rlgl.ReadScreenPixels(w, h)
	if pixels == nil {
		return false
	}
	defer rl.MemFree(pixels)
	return rl.ExportImage({data = pixels, width = w, height = h, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8A8}, path)
}

element_box :: proc(id: string, index: u32 = 0) -> (clay.BoundingBox, bool) {
	data := clay.GetElementData(clay.ID(id, index))
	if !data.found {
		return {}, false
	}
	return data.boundingBox, true
}

region :: proc(id: string, index: u32 = 0) -> (clay.BoundingBox, bool) {
	return element_box(id, index)
}

begin_clip :: proc(id: string, index: u32 = 0) -> bool {
	box, ok := element_box(id, index)
	if !ok {
		return false
	}
	set_scissor(box)
	return true
}

end_clip :: proc() {
	rl.EndScissorMode()
}

element_hovered :: proc(id: string, index: u32 = 0) -> bool {
	return clay.PointerOver(clay.ID(id, index))
}

@(private)
s_interactions_enabled := true

set_interactions_enabled :: proc(enabled: bool) {
	s_interactions_enabled = enabled
}

// A press over the element this frame. Hit-tested by Clay like `hovered`, so
// a click on an open menu doesn't also land on what's under it, and a
// control scrolled out of its container's clip can't be clicked.
clicked :: proc(id: string, index: u32 = 0) -> bool {
	return s_interactions_enabled && mouse_pressed(.Left) && element_hovered(id, index)
}

Stats :: struct {
	fps:        i32,
	frame_ms:   f32,
	busy_ms:    f32,
	clay_kb:    int,
	cmds:       int,
	custom:     int,
	custom_max: int,
	zoom:       f32,
}

stats :: proc() -> Stats {
	return {
		fps        = shown_fps,
		frame_ms   = frame_dt * 1000,
		busy_ms    = busy_dt * 1000,
		clay_kb    = (len(clay_memory) + 1023) / 1024,
		cmds       = last_cmd_count,
		custom     = len(s_custom),
		custom_max = CUSTOM_RESERVE,
		zoom       = zoom,
	}
}
