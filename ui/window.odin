package ui

import "core:math"
import "core:strings"
import rl "../deps/raylib"

// The window's scale and zoom, the clipboard, the pointer's shape and fullscreen.

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
