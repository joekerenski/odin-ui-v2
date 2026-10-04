package ui

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"
import clay "../deps/clay"

// Font slots (a face and its nominal size, by Clay font id) and measuring text with them, the
// way glyphs.odin draws it.

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
