package ui

import clay "../deps/clay"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import rl "../deps/raylib"
import rlgl "../deps/raylib/rlgl"

Region_Box :: clay.BoundingBox

// Window, frame loop, Clay lifecycle, and font slots (glyphs.odin draws them).
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

// A font comes from a file (`path`, owned) or from memory (`data`, borrowed:
// typically #load'ed, so it lives as long as the program). Its glyphs are
// rasterized on demand at each size drawn (see glyphs.odin).
Font_Slot :: struct {
	face: Face_Id,
	size: u16,
	path: string,
	data: []u8,
}

@(private)
fonts: [dynamic]Font_Slot

@(private)
shapes_tex: rl.Texture2D

// Pixels per point the glyph cache holds (display scale * zoom).
@(private)
loaded_scale: f32

// UI zoom in effect. Everything the UI lays out is in "layout units"; one
// unit is `zoom` points. Change it with set_zoom / zoom_in / zoom_out, which
// apply at the start of the next frame so a frame never mixes two zooms.
// It can sit below the requested zoom: see fit_zoom.
zoom: f32 = 1

ZOOM_STEPS := [?]f32{0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2}

@(private)
pending_zoom: f32 = 1

@(private)
min_size: [2]f32

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

dpi_scale :: proc() -> f32 {
	s := rl.GetWindowScaleDPI().x
	if s <= 0 {
		return 1
	}
	return s
}

// Pixels per layout unit: the display scale times the zoom.
raster_scale :: proc() -> f32 {
	return dpi_scale() * zoom
}

// Takes effect at the start of the next frame. Clamped to the ZOOM_STEPS
// range, and a zoom-in that would squeeze the layout below the window's
// minimum size is refused.
set_zoom :: proc(z: f32) {
	z := math.clamp(z, ZOOM_STEPS[0], ZOOM_STEPS[len(ZOOM_STEPS) - 1])
	if z > pending_zoom && !zoom_fits(z) {
		return
	}
	pending_zoom = z
}

// The layout at zoom `z` is at least the window's minimum size.
@(private)
zoom_fits :: proc(z: f32) -> bool {
	w, h := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	return w / z >= min_size.x && h / z >= min_size.y
}

// The zoom to use this frame: the largest step at or below `requested` whose
// layout still fits the minimum size, never below 1 (or `requested`, if that
// is lower). A window shrunk after zooming in, or tiled smaller by the
// compositor, steps the zoom down instead of squeezing the layout. Whole steps
// only, so a resize drag re-rasterizes fonts at step changes, not every frame.
@(private)
fit_zoom :: proc(requested: f32) -> f32 {
	floor := min(requested, 1)
	if requested <= floor || zoom_fits(requested) {
		return requested
	}
	#reverse for z in ZOOM_STEPS {
		if z < requested && (z <= floor || zoom_fits(z)) {
			return max(z, floor)
		}
	}
	return floor
}

zoom_in :: proc() {
	for z in ZOOM_STEPS {
		if z > pending_zoom + 0.001 {
			set_zoom(z)
			return
		}
	}
}

zoom_out :: proc() {
	#reverse for z in ZOOM_STEPS {
		if z < pending_zoom - 0.001 {
			set_zoom(z)
			return
		}
	}
}

// Ctrl + = / - / 0 (Cmd on macOS), keypad too. Shift is allowed, since + is
// Shift+= on most layouts.
zoom_shortcuts :: proc() {
	mod: Mod = .Super when ODIN_OS == .Darwin else .Ctrl
	if mod not_in input.mods || input.mods - {mod, .Shift} != {} {
		return
	}
	if key_pressed(.Plus) || key_pressed(.KP_Add) {
		zoom_in()
	}
	if key_pressed(.Minus) || key_pressed(.KP_Subtract) {
		zoom_out()
	}
	if key_pressed(.Zero) || key_pressed(.KP_0) {
		set_zoom(1)
	}
}

framebuffer_size :: proc() -> (i32, i32) {
	return rl.GetRenderWidth(), rl.GetRenderHeight()
}

set_clipboard :: proc(text: string) {
	rl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
}

// The clipboard's text, "" when it holds none. Temp allocated by default.
get_clipboard :: proc(allocator := context.temp_allocator) -> string {
	c := rl.GetClipboardText()
	if c == nil {
		return ""
	}
	return strings.clone(string(c), allocator)
}

// The mouse pointer's shape. A widget asks for one while it builds (the
// text cursor over a field); the last ask of a frame wins, and a frame with
// none goes back to the arrow.
Cursor :: enum u8 {
	Arrow,
	Text,
	Hand,
}

@(private)
s_cursor_want, s_cursor_set: Cursor

request_cursor :: proc(c: Cursor) {
	s_cursor_want = c
}

toggle_fullscreen :: proc() {
	when ODIN_OS == .Darwin {
		darwin_toggle_fullscreen()
	} else when ODIN_OS == .Linux {
		if wayland_active() {
			wayland_toggle_fullscreen()
		} else {
			rl.ToggleFullscreen()
		}
	} else {
		rl.ToggleFullscreen()
	}
}

is_fullscreen :: proc() -> bool {
	when ODIN_OS == .Darwin {
		return darwin_is_fullscreen()
	} else when ODIN_OS == .Linux {
		if wayland_active() {
			return wayland_is_fullscreen()
		}
		return rl.IsWindowFullscreen()
	} else {
		return rl.IsWindowFullscreen()
	}
}

// Glyphs are rasterized at fontSize * display scale, so each texel is one
// framebuffer pixel when drawn at `size` in point space.
load_font :: proc(font_id: u16, size: u16, path: cstring) {
	f := reset_font_slot(font_id, size)
	f.path = strings.clone(string(path))
	f.face = face_from_path(f.path)
	if f.face == NO_FACE {
		warn_font(f^)
	}
}

// Same from TTF/OTF bytes, e.g. `#load("fonts/Inter-Medium.ttf")`, so the
// binary doesn't depend on the working directory. `data` must outlive the UI.
load_font_data :: proc(font_id: u16, size: u16, data: []u8) {
	f := reset_font_slot(font_id, size)
	f.data = data
	f.face = face_from_data(data)
	if f.face == NO_FACE {
		warn_font(f^)
	}
}

// Faces stay loaded until shutdown (another slot may share one).
@(private)
reset_font_slot :: proc(font_id: u16, size: u16) -> ^Font_Slot {
	ensure_font_slot(font_id)
	f := &fonts[font_id]
	delete(f.path)
	f^ = {face = NO_FACE, size = size}
	return f
}

// The size to draw (and measure) text at, in layout units. Glyphs are
// rasterized at round(size * raster_scale) pixels, so that is the size text
// draws at: at a 1.25 display scale 14pt is 17.5px, drawn as 18px, so a 14pt
// label draws at 14.4pt there, and at exactly 14pt at 1x and 2x. Resampling
// glyphs to the nominal size instead is what blurs text.
text_draw_size :: proc(font_id: u16, font_size: u16) -> f32 {
	if slot_face(font_id) == NO_FACE {
		return f32(font_size)
	}
	return slot_px(font_id, font_size) / raster_scale()
}

@(private)
ensure_font_slot :: proc(id: u16) {
	for len(fonts) <= int(id) {
		append(&fonts, Font_Slot{face = NO_FACE})
	}
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

// Matches draw_text: rounded pixel advances, spacing added per codepoint.
@(private)
measure_text :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	userData: rawptr,
) -> clay.Dimensions {
	context = runtime.default_context()
	s := string(text.chars[:text.length])
	return {
		width  = text_width(s, config.fontId, config.fontSize, f32(config.letterSpacing)),
		height = text_draw_size(config.fontId, config.fontSize),
	}
}

// The width `s` draws at in layout units, as Clay measures it: the same
// sum of advances draw_text makes.
text_width :: proc(s: string, font_id: u16, font_size: u16, letter_spacing: f32 = 0) -> f32 {
	face := slot_face(font_id)
	if face == NO_FACE {
		return f32(utf8.rune_count_in_string(s)) * f32(font_size) * 0.5
	}
	px := slot_px(font_id, font_size)
	width, spacing: f32
	for r in s {
		if r == '\n' || r == '\r' {
			continue
		}
		_, _, _, adv := rune_glyph(face, r, px)
		width += adv
		spacing += letter_spacing
	}
	return width / raster_scale() + spacing
}

// One codepoint's advance in layout units; text_width of a string is the
// sum of these (with no letter spacing).
rune_width :: proc(r: rune, font_id: u16, font_size: u16) -> f32 {
	face := slot_face(font_id)
	if face == NO_FACE {
		return f32(font_size) * 0.5
	}
	_, _, _, adv := rune_glyph(face, r, slot_px(font_id, font_size))
	return adv / raster_scale()
}

@(private)
poll_input :: proc() {
	took_mouse, took_keys := false, false
	when ODIN_OS == .Darwin {
		took_mouse = darwin_take_mouse()
		took_keys = darwin_take_keys()
	}
	if !took_mouse {
		mp := rl.GetMousePosition()
		input.mouse_x = mp.x
		input.mouse_y = mp.y
		md := rl.GetMouseDelta()
		input.mouse_delta_x = md.x
		input.mouse_delta_y = md.y
		wheel := rl.GetMouseWheelMoveV()
		input.wheel_x = wheel.x
		input.wheel_y = wheel.y
		input.mouse_down = 0
		input.mouse_pressed = 0
		input.mouse_released = 0
		if rl.IsMouseButtonDown(.LEFT) do input.mouse_down |= 1 << u8(Mouse_Button.Left)
		if rl.IsMouseButtonDown(.RIGHT) do input.mouse_down |= 1 << u8(Mouse_Button.Right)
		if rl.IsMouseButtonDown(.MIDDLE) do input.mouse_down |= 1 << u8(Mouse_Button.Middle)
		if rl.IsMouseButtonPressed(.LEFT) do input.mouse_pressed |= 1 << u8(Mouse_Button.Left)
		if rl.IsMouseButtonPressed(.RIGHT) do input.mouse_pressed |= 1 << u8(Mouse_Button.Right)
		if rl.IsMouseButtonPressed(.MIDDLE) do input.mouse_pressed |= 1 << u8(Mouse_Button.Middle)
		if rl.IsMouseButtonReleased(.LEFT) do input.mouse_released |= 1 << u8(Mouse_Button.Left)
		if rl.IsMouseButtonReleased(.RIGHT) do input.mouse_released |= 1 << u8(Mouse_Button.Right)
		if rl.IsMouseButtonReleased(.MIDDLE) do input.mouse_released |= 1 << u8(Mouse_Button.Middle)
	}
	// Points to layout units.
	input.mouse_x /= zoom
	input.mouse_y /= zoom
	input.mouse_delta_x /= zoom
	input.mouse_delta_y /= zoom

	// Text comes from GLFW's character callback everywhere (macOS too: the
	// monitor passes key events on), which applies the layout, Option and
	// dead keys. Cmd combinations type nothing.
	input.char_count = 0
	for r := rl.GetCharPressed(); r != 0; r = rl.GetCharPressed() {
		// Control characters, and macOS's private-use function-key range.
		if r < 0x20 || r == 0x7f || (r >= 0xf700 && r <= 0xf8ff) {
			continue
		}
		if input.char_count < len(input.chars) {
			input.chars[input.char_count] = r
			input.char_count += 1
		}
	}
	if took_keys {
		return
	}

	// Raylib only compares key state between polls, so a tap that starts and
	// ends inside one poll is lost here. macOS takes keys from the monitor.
	input.keys_pressed = {}
	input.keys_down = {}
	input.keys_repeat = {}
	input.mods = {}
	if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) do input.mods += {.Shift}
	if rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) do input.mods += {.Ctrl}
	if rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT) do input.mods += {.Alt}
	if rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER) do input.mods += {.Super}
	poll_key(.Escape, .ESCAPE)
	poll_key(.Enter, .ENTER)
	poll_key(.Space, .SPACE)
	poll_key(.Tab, .TAB)
	poll_key(.Backspace, .BACKSPACE)
	poll_key(.Delete, .DELETE)
	poll_key(.Left, .LEFT)
	poll_key(.Right, .RIGHT)
	poll_key(.Up, .UP)
	poll_key(.Down, .DOWN)
	poll_key(.A, .A); poll_key(.B, .B); poll_key(.C, .C); poll_key(.D, .D)
	poll_key(.E, .E); poll_key(.F, .F); poll_key(.G, .G); poll_key(.H, .H)
	poll_key(.I, .I); poll_key(.J, .J); poll_key(.K, .K); poll_key(.L, .L)
	poll_key(.M, .M); poll_key(.N, .N); poll_key(.O, .O); poll_key(.P, .P)
	poll_key(.Q, .Q); poll_key(.R, .R); poll_key(.S, .S); poll_key(.T, .T)
	poll_key(.U, .U); poll_key(.V, .V); poll_key(.W, .W); poll_key(.X, .X)
	poll_key(.Y, .Y); poll_key(.Z, .Z)
	poll_key(.F1, .F1); poll_key(.F3, .F3)
	poll_key(.Home, .HOME); poll_key(.End, .END)
	poll_key(.Page_Up, .PAGE_UP); poll_key(.Page_Down, .PAGE_DOWN)
	poll_key(.KP_Add, .KP_ADD); poll_key(.KP_Subtract, .KP_SUBTRACT); poll_key(.KP_0, .KP_0)

	// raylib names keys by their US position, so on a German layout + comes
	// in as RIGHT_BRACKET and - as SLASH. Match these by what they type.
	for k := rl.GetKeyPressed(); k != .KEY_NULL; k = rl.GetKeyPressed() {
		switch string(rl.GetKeyName(k)) {
		case "+", "=":
			input.keys_pressed += {.Plus}
		case "-":
			input.keys_pressed += {.Minus}
		case "0":
			input.keys_pressed += {.Zero}
		}
	}
}

@(private)
poll_key :: proc(k: Key, rk: rl.KeyboardKey) {
	if rl.IsKeyPressed(rk) {
		input.keys_pressed += {k}
		input.keys_repeat += {k}
	} else if rl.IsKeyPressedRepeat(rk) {
		input.keys_repeat += {k}
	}
	if rl.IsKeyDown(rk) {
		input.keys_down += {k}
	}
}
