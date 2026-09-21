package ui

import clay "../deps/clay"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

Region_Box :: clay.BoundingBox

// Window, frame loop, Clay lifecycle, and the font atlas.
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
// `frame` polls input and, on macOS, waits until a display-link tick has
// landed since the previous frame. Present stays unsynced (swap interval 0);
// the link is the clock, so a fullscreen flush that already blocked a vblank
// does not get a second wait.

Window_Desc :: struct {
	title:      cstring,
	width:      i32,
	height:     i32,
	resizable:  bool,
	high_dpi:   bool,
	msaa_4x:    bool,
	target_fps: i32, // 0 = the display's refresh
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

Font_Slot :: struct {
	font: rl.Font,
	size: u16,
	path: string,
}

@(private)
fonts: [dynamic]Font_Slot

@(private)
shapes_tex: rl.Texture2D

@(private)
loaded_dpi: f32

init :: proc(desc: Window_Desc) {
	target_fps = desc.target_fps
	quit_requested = false

	flags: rl.ConfigFlags
	if desc.resizable do flags += {.WINDOW_RESIZABLE}
	if desc.high_dpi do flags += {.WINDOW_HIGHDPI}
	if desc.msaa_4x do flags += {.MSAA_4X_HINT}
	// macOS GL swap interval does not track ProMotion and falls apart when the
	// window is occluded. The display link in darwin.odin is the clock there.
	when ODIN_OS != .Darwin {
		flags += {.VSYNC_HINT}
	}
	rl.SetConfigFlags(flags)
	rl.InitWindow(desc.width, desc.height, desc.title)
	rl.SetExitKey(rl.KeyboardKey.KEY_NULL)
	// UI fills are triangles that sample this texel. DrawRectangle's quads do
	// not rasterize on the macOS GL 4.1 context, and a triangle with no
	// texcoord samples the font atlas and disappears.
	white := rl.GenImageColor(1, 1, rl.WHITE)
	shapes_tex = rl.LoadTextureFromImage(white)
	rl.UnloadImage(white)
	rl.SetShapesTexture(shapes_tex, {0, 0, 1, 1})

	when ODIN_OS == .Darwin {
		darwin_start()
	}

	screen_w = f32(rl.GetScreenWidth())
	screen_h = f32(rl.GetScreenHeight())
	frame_dt = 1.0 / 60.0
	loaded_dpi = dpi_scale()

	input = {}
	input.keys_pressed = make(map[Key]bool)
	input.keys_down = make(map[Key]bool)

	clay_setup(desc)
	reset_styles()
	custom_setup()
}

shutdown :: proc() {
	when ODIN_OS == .Darwin {
		darwin_stop()
	}
	for &f in fonts {
		if f.font.glyphCount > 0 {
			rl.UnloadFont(f.font)
		}
		delete(f.path)
	}
	delete(fonts)
	fonts = nil
	custom_teardown()
	delete(clay_memory)
	clay_memory = nil
	delete(input.keys_pressed)
	delete(input.keys_down)
	if shapes_tex.id != 0 {
		rl.UnloadTexture(shapes_tex)
	}
	rl.CloseWindow()
}

// Poll, pace, and report whether the window is still open.
// Call once per frame before building the UI.
frame :: proc() -> bool {
	when ODIN_OS == .Darwin {
		darwin_pace()
	} else {
		frame_dt = rl.GetFrameTime()
		if frame_dt <= 0 {
			frame_dt = 1.0 / 60.0
		}
	}
	if quit_requested || rl.WindowShouldClose() {
		return false
	}

	screen_w = f32(rl.GetScreenWidth())
	screen_h = f32(rl.GetScreenHeight())
	poll_input()

	dpi := dpi_scale()
	if dpi > 0 && math.abs(dpi - loaded_dpi) > 0.01 && len(fonts) > 0 {
		loaded_dpi = dpi
		reload_fonts()
	}

	if frame_dt > 0 && fps_acc < 0.5 {
		shown_fps = i32(math.round(1.0 / frame_dt))
	}
	fps_acc += frame_dt
	fps_frames += 1
	if fps_acc >= 0.5 {
		shown_fps = i32(math.round(f32(fps_frames) / fps_acc))
		fps_acc = 0
		fps_frames = 0
	}

	frame_start = time.now()
	return true
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

framebuffer_size :: proc() -> (i32, i32) {
	return rl.GetRenderWidth(), rl.GetRenderHeight()
}

toggle_fullscreen :: proc() {
	when ODIN_OS == .Darwin {
		darwin_toggle_fullscreen()
	} else {
		rl.ToggleFullscreen()
	}
}

is_fullscreen :: proc() -> bool {
	when ODIN_OS == .Darwin {
		return darwin_is_fullscreen()
	} else {
		return rl.IsWindowFullscreen()
	}
}

glyph_font :: proc(id: u16) -> rl.Font {
	if int(id) >= len(fonts) {
		return {}
	}
	return fonts[id].font
}

// Rasterize at fontSize * display scale so each glyph texel is one framebuffer
// pixel when drawn at `size` in point space. Filter is bilinear with no mips:
// trilinear mipmaps are what softens UI text.
load_font :: proc(font_id: u16, size: u16, path: cstring) {
	ensure_font_slot(font_id)
	if fonts[font_id].font.glyphCount > 0 {
		rl.UnloadFont(fonts[font_id].font)
	}
	delete(fonts[font_id].path)
	fonts[font_id].path = strings.clone(string(path))
	fonts[font_id].size = size
	fonts[font_id].font = rasterize(fonts[font_id].path, size)
	loaded_dpi = dpi_scale()
}

@(private)
reload_fonts :: proc() {
	for &f in fonts {
		if f.path == "" {
			continue
		}
		if f.font.glyphCount > 0 {
			rl.UnloadFont(f.font)
		}
		f.font = rasterize(f.path, f.size)
	}
}

@(private)
rasterize :: proc(path: string, size: u16) -> rl.Font {
	px := i32(math.round(f32(size) * dpi_scale()))
	if px < 1 {
		px = i32(size)
	}
	cstr := strings.clone_to_cstring(path)
	defer delete(cstr)
	font := rl.LoadFontEx(cstr, px, nil, 0)
	if font.glyphCount > 0 {
		rl.SetTextureFilter(font.texture, .BILINEAR)
	} else {
		fmt.eprintln("ui: font failed to load:", path)
	}
	return font
}

@(private)
ensure_font_slot :: proc(id: u16) {
	for len(fonts) <= int(id) {
		append(&fonts, Font_Slot{})
	}
}

@(private)
clay_error :: proc "c" (data: clay.ErrorData) {
	context = runtime.default_context()
	fmt.eprintln("clay:", data.errorType)
}

@(private)
clay_setup :: proc(desc: Window_Desc) {
	min_mem := clay.MinMemorySize()
	clay_memory = make([]u8, int(min_mem))
	arena := clay.CreateArenaWithCapacityAndMemory(c.size_t(min_mem), &clay_memory[0])
	clay.Initialize(arena, {f32(desc.width), f32(desc.height)}, {handler = clay_error})
	clay.SetMeasureTextFunction(measure_text, nil)
}

begin_layout :: proc() {
	custom_begin_frame()
	clay.SetLayoutDimensions({screen_w, screen_h})
	clay.SetPointerState({input.mouse_x, input.mouse_y}, mouse_down(.Left))
	clay.UpdateScrollContainers(false, {input.wheel_x, input.wheel_y}, frame_dt)
	clay.BeginLayout()
}

end_layout :: proc() -> clay.ClayArray(clay.RenderCommand) {
	cmds := clay.EndLayout(frame_dt)
	last_cmd_count = int(cmds.length)
	return cmds
}

begin_draw :: proc() {
	rl.BeginDrawing()
	rl.ClearBackground(to_rl_color(theme.bg))
}

end_draw :: proc() {
	rl.EndDrawing()
	busy_dt = f32(time.duration_seconds(time.since(frame_start)))
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
	rl.BeginScissorMode(
		i32(math.round(box.x)),
		i32(math.round(box.y)),
		i32(math.round(box.width)),
		i32(math.round(box.height)),
	)
	return true
}

end_clip :: proc() {
	rl.EndScissorMode()
	rlgl.DisableScissorTest()
}

element_hovered :: proc(id: string, index: u32 = 0) -> bool {
	return clay.PointerOver(clay.ID(id, index))
}

@(private)
s_interactions_enabled := true

set_interactions_enabled :: proc(enabled: bool) {
	s_interactions_enabled = enabled
}

clicked :: proc(id: string, index: u32 = 0) -> bool {
	if !s_interactions_enabled || !mouse_pressed(.Left) {
		return false
	}
	box, ok := element_box(id, index)
	if !ok {
		return false
	}
	return mouse_in_box(box)
}

Stats :: struct {
	fps:        i32,
	frame_ms:   f32,
	busy_ms:    f32,
	clay_kb:    int,
	cmds:       int,
	custom:     int,
	custom_max: int,
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
	}
}

// Match DrawTextEx: advances from the atlas, scaled by fontSize/baseSize,
// spacing added once per codepoint. Atlas pixels are `size * dpi`, so the
// scale lands on 1 texel per framebuffer pixel.
@(private)
measure_text :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	userData: rawptr,
) -> clay.Dimensions {
	context = runtime.default_context()
	if int(config.fontId) >= len(fonts) || fonts[config.fontId].font.glyphCount <= 0 {
		return {width = f32(text.length) * f32(config.fontSize) * 0.5, height = f32(config.fontSize)}
	}
	font := fonts[config.fontId].font
	s := string(text.chars[:text.length])
	width: f32
	i := 0
	for i < len(s) {
		r, w := utf8.decode_rune_in_string(s[i:])
		if w <= 0 {
			break
		}
		idx := int(rl.GetGlyphIndex(font, r))
		if idx >= 0 && idx < int(font.glyphCount) {
			g := font.glyphs[idx]
			if g.advanceX != 0 {
				width += f32(g.advanceX)
			} else {
				width += font.recs[idx].width + f32(g.offsetX)
			}
		}
		width += f32(config.letterSpacing)
		i += w
	}
	scale := f32(config.fontSize) / f32(font.baseSize)
	if font.baseSize == 0 {
		scale = 1
	}
	return {width = width * scale, height = f32(config.fontSize)}
}

@(private)
poll_input :: proc() {
	clear(&input.keys_pressed)
	clear(&input.keys_down)

	took_mouse := false
	when ODIN_OS == .Darwin {
		took_mouse = darwin_take_mouse()
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
}

@(private)
poll_key :: proc(k: Key, rk: rl.KeyboardKey) {
	if rl.IsKeyPressed(rk) {
		input.keys_pressed[k] = true
	}
	if rl.IsKeyDown(rk) {
		input.keys_down[k] = true
	}
}
