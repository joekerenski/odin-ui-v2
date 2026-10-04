package ui

import rl "../deps/raylib"
import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import stbtt "vendor:stb/truetype"

// Text is drawn from a glyph cache: fonts are read with stb_truetype, and each glyph is
// rasterized the first time it is drawn, at the size it is drawn (in physical pixels, so one
// texel is one pixel), into atlas pages. A character the font lacks comes from the first
// fallback font that has it: ones the app adds, then a few the system usually has (symbols,
// wide-coverage, CJK). Glyphs can also be drawn by glyph id (draw_glyph), which a math layout
// needs: its stretched delimiters and big operators are glyphs with no character code.
//
// Shaping (ligatures, contextual forms, right-to-left) is not done; scripts that need it draw
// their characters one by one.

Face_Id :: distinct int

NO_FACE :: Face_Id(-1)

@(private)
Face :: struct {
	info:    stbtt.fontinfo,
	data:    []u8,
	owned:   bool, // data read from `path` (freed at shutdown), else borrowed
	path:    string,
	ascent:  i32, // font units
	descent: i32,
	gap:     i32,
}

@(private)
s_faces: [dynamic]Face

// A face from TTF/OTF/TTC bytes that outlive the UI (#load'ed). The same bytes give the same face.
face_from_data :: proc(data: []u8, index := 0) -> Face_Id {
	for &f, i in s_faces {
		if !f.owned && raw_data(f.data) == raw_data(data) && len(f.data) == len(data) { return Face_Id(i) }
	}
	return add_face(data, false, "", index)
}

// A face from a font file (read once; the same path gives the same face). NO_FACE if it can't
// be read or parsed.
face_from_path :: proc(path: string, index := 0) -> Face_Id {
	for &f, i in s_faces {
		if f.path == path { return Face_Id(i) }
	}
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return NO_FACE }
	id := add_face(data, true, path, index)
	if id == NO_FACE { delete(data) }
	return id
}

@(private)
add_face :: proc(data: []u8, owned: bool, path: string, index: int) -> Face_Id {
	f := Face{data = data, owned = owned, path = strings.clone(path)}
	offset := stbtt.GetFontOffsetForIndex(raw_data(data), c.int(index))
	if offset < 0 || !stbtt.InitFont(&f.info, raw_data(data), offset) {
		delete(f.path)
		return NO_FACE
	}
	stbtt.GetFontVMetrics(&f.info, &f.ascent, &f.descent, &f.gap)
	append(&s_faces, f)
	return Face_Id(len(s_faces) - 1)
}

// The face's scale from font units to pixels at a pixel height (ascent to descent).
face_scale :: proc(face: Face_Id, px: f32) -> f32 {
	return stbtt.ScaleForPixelHeight(&s_faces[face].info, px)
}

// The face's glyph for a character, 0 (.notdef) when it has none.
face_glyph :: proc(face: Face_Id, r: rune) -> u32 {
	return u32(stbtt.FindGlyphIndex(&s_faces[face].info, r))
}

face_ascent :: proc(face: Face_Id) -> i32 { return s_faces[face].ascent }

// A glyph's advance in pixels at pixel height px, rounded as drawn.
glyph_advance_px :: proc(face: Face_Id, glyph: u32, px: f32) -> f32 {
	adv, lsb: c.int
	stbtt.GetGlyphHMetrics(&s_faces[face].info, c.int(glyph), &adv, &lsb)
	return math.round(f32(adv) * face_scale(face, px))
}

// --- fallback fonts ----------------------------------------------------------------------

@(private)
Fallback :: struct {
	path:  string, // "" when added from data
	data:  []u8,
	face:  Face_Id,
	tried: bool,
}

@(private)
s_fallbacks: [dynamic]Fallback

@(private)
s_system_fallbacks_added: bool

// A font to take characters from when a text's own font lacks them, tried in the order added,
// before the system's. Loaded the first time it's needed.
add_fallback_font :: proc(path: string) {
	append(&s_fallbacks, Fallback{path = strings.clone(path), face = NO_FACE})
}

add_fallback_font_data :: proc(data: []u8) {
	append(&s_fallbacks, Fallback{data = data, face = NO_FACE})
}

// Fonts most systems have: math, Greek and arrows (STIX, sized like text), other symbols, then
// wide coverage, then CJK. Missing ones are skipped when tried.
@(private)
SYSTEM_FALLBACKS :: [?]string{
	"/System/Library/Fonts/Supplemental/STIXGeneral.otf",
	"/System/Library/Fonts/Apple Symbols.ttf",
	"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
	"/System/Library/Fonts/Hiragino Sans GB.ttc",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf",
	"/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf",
	"/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
}

// Which face draws `r` for text in `primary`: primary itself, or the first fallback that has
// it, or primary's .notdef. Remembered.
@(private)
s_resolved: map[u64]u64

resolve_glyph :: proc(primary: Face_Id, r: rune) -> (face: Face_Id, glyph: u32) {
	if g := face_glyph(primary, r); g != 0 || r < 0x80 { return primary, g }
	key := u64(primary) << 32 | u64(u32(r))
	if v, ok := s_resolved[key]; ok { return Face_Id(v >> 32), u32(v) }
	face, glyph = primary, 0
	if !s_system_fallbacks_added {
		s_system_fallbacks_added = true
		for p in SYSTEM_FALLBACKS { add_fallback_font(p) }
	}
	for &fb in s_fallbacks {
		if !fb.tried {
			fb.tried = true
			if fb.path != "" {
				if os.is_file(fb.path) { fb.face = face_from_path(fb.path) }
			} else {
				fb.face = face_from_data(fb.data)
			}
		}
		if fb.face == NO_FACE || fb.face == primary { continue }
		if g := face_glyph(fb.face, r); g != 0 {
			face, glyph = fb.face, g
			break
		}
	}
	s_resolved[key] = u64(face) << 32 | u64(glyph)
	return
}

// --- the atlas ---------------------------------------------------------------------------

@(private)
PAGE :: 1024

@(private)
MAX_PAGES :: 12

@(private)
Page :: struct {
	tex:     rl.Texture2D,
	shelf_x: i32,
	shelf_y: i32,
	shelf_h: i32,
}

@(private)
Glyph_Key :: struct {
	face:  Face_Id,
	glyph: u32,
	px:    u16,
}

@(private)
Cached_Glyph :: struct {
	page:   i32, // -1: nothing to draw (a space)
	rect:   rl.Rectangle, // in the page
	ox, oy: f32, // bitmap's top-left from the pen at the baseline, pixels
}

@(private)
s_pages: [dynamic]Page

@(private)
s_glyphs: map[Glyph_Key]Cached_Glyph

// Drops every rasterized glyph (the display scale or zoom changed: new pixel sizes).
glyph_cache_clear :: proc() {
	for p in s_pages { rl.UnloadTexture(p.tex) }
	clear(&s_pages)
	clear(&s_glyphs)
}

@(private)
glyphs_teardown :: proc() {
	glyph_cache_clear()
	delete(s_pages)
	delete(s_glyphs)
	for f in s_faces {
		if f.owned { delete(f.data) }
		delete(f.path)
	}
	delete(s_faces)
	for fb in s_fallbacks { delete(fb.path) }
	delete(s_fallbacks)
	delete(s_resolved)
	s_pages, s_glyphs, s_faces, s_fallbacks, s_resolved = nil, nil, nil, nil, nil
	s_system_fallbacks_added = false
}

@(private)
cached_glyph :: proc(face: Face_Id, glyph: u32, px: f32) -> Cached_Glyph {
	key := Glyph_Key{face, glyph, u16(px)}
	if g, ok := s_glyphs[key]; ok { return g }
	g := rasterize_glyph(face, glyph, px)
	s_glyphs[key] = g
	return g
}

@(private)
rasterize_glyph :: proc(face: Face_Id, glyph: u32, px: f32) -> Cached_Glyph {
	f := &s_faces[face]
	s := face_scale(face, px)
	x0, y0, x1, y1: c.int
	stbtt.GetGlyphBitmapBox(&f.info, c.int(glyph), s, s, &x0, &y0, &x1, &y1)
	w, h := i32(x1 - x0), i32(y1 - y0)
	if w <= 0 || h <= 0 { return {page = -1} }
	if w > PAGE - 2 || h > PAGE - 2 { return {page = -1} } // absurdly big: skip

	page, x, y := alloc_rect(w, h)
	if page < 0 { return {page = -1} }
	coverage := make([]u8, w * h, context.temp_allocator)
	stbtt.MakeGlyphBitmap(&f.info, raw_data(coverage), c.int(w), c.int(h), c.int(w), s, s, c.int(glyph))
	// White, with the coverage as alpha, so the draw color tints it.
	pixels := make([]u8, w * h * 2, context.temp_allocator)
	for v, k in coverage {
		pixels[2 * k] = 255
		pixels[2 * k + 1] = v
	}
	rect := rl.Rectangle{f32(x), f32(y), f32(w), f32(h)}
	rl.UpdateTextureRec(s_pages[page].tex, rect, raw_data(pixels))
	return {page = page, rect = rect, ox = f32(x0), oy = f32(y0)}
}

// A w×h spot in a page (shelf packing, 1px apart). A new page when they're full; when there
// are too many, start over.
@(private)
alloc_rect :: proc(w, h: i32) -> (page, x, y: i32) {
	for &p, i in s_pages {
		if p.shelf_x + w + 1 > PAGE {
			p.shelf_y += p.shelf_h + 1
			p.shelf_x, p.shelf_h = 0, 0
		}
		if p.shelf_y + h + 1 <= PAGE {
			x, y = p.shelf_x, p.shelf_y
			p.shelf_x += w + 1
			p.shelf_h = max(p.shelf_h, h)
			return i32(i), x, y
		}
	}
	if len(s_pages) >= MAX_PAGES {
		glyph_cache_clear()
	}
	img := rl.GenImageColor(PAGE, PAGE, {255, 255, 255, 0})
	rl.ImageFormat(&img, .UNCOMPRESSED_GRAY_ALPHA)
	tex := rl.LoadTextureFromImage(img)
	rl.UnloadImage(img)
	rl.SetTextureFilter(tex, .BILINEAR)
	append(&s_pages, Page{tex = tex, shelf_x = w + 1, shelf_h = h})
	return i32(len(s_pages) - 1), 0, 0
}

// --- drawing -----------------------------------------------------------------------------

// Glyph `glyph` of `face` at pixel height px, its pen at (x, y) on the baseline, in layout
// units. For text, use draw_text; this is for layouts that place glyphs themselves (math).
draw_glyph :: proc(face: Face_Id, glyph: u32, px: f32, x, y: f32, color: Color) {
	g := cached_glyph(face, glyph, px)
	if g.page < 0 { return }
	rs := raster_scale()
	dst := rl.Rectangle{snap_px(x + g.ox / rs), snap_px(y + g.oy / rs), g.rect.width / rs, g.rect.height / rs}
	rl.DrawTexturePro(s_pages[g.page].tex, g.rect, dst, {0, 0}, 0, to_rl_color(color))
}

// `s` in a font slot at a size, its top-left at (x, y) in layout units (as Clay places text).
draw_text :: proc(s: string, x, y: f32, font_id: u16, font_size: u16, color: Color, letter_spacing: f32 = 0) {
	face := slot_face(font_id)
	if face == NO_FACE { return }
	rs := raster_scale()
	px := slot_px(font_id, font_size)
	baseline := snap_px(y + f32(face_ascent(face)) * face_scale(face, px) / rs)
	pen := x
	for r in s {
		if r == '\n' || r == '\r' { continue }
		gf, gi, gpx, adv := rune_glyph(face, r, px)
		if r != ' ' && r != '\t' { draw_glyph(gf, gi, gpx, pen, baseline, color) }
		pen += adv / rs + letter_spacing
	}
}

// The face and glyph that draw `r` in `face` at pixel height px, the pixel height to draw it at,
// and its advance in pixels. A tab is four spaces.
@(private)
rune_glyph :: proc(face: Face_Id, r: rune, px: f32) -> (gf: Face_Id, gi: u32, gpx: f32, adv: f32) {
	if r == '\t' {
		gi = face_glyph(face, ' ')
		return face, gi, px, 4 * glyph_advance_px(face, gi, px)
	}
	gf, gi = resolve_glyph(face, r)
	gpx = px if gf == face else fallback_px(face, gf, px)
	return gf, gi, gpx, glyph_advance_px(gf, gi, gpx)
}

// The pixel height that gives `fallback` the em size `primary` has at px. Pixel heights span
// ascent to descent, which fonts set very differently (symbol fonts make room for tall
// operators); matching the em instead makes borrowed characters the size of their neighbors.
@(private)
fallback_px :: proc(primary, fallback: Face_Id, px: f32) -> f32 {
	em := face_scale(primary, px) / stbtt.ScaleForMappingEmToPixels(&s_faces[primary].info, 1)
	f := &s_faces[fallback]
	return max(1, math.round(em * f32(f.ascent - f.descent) * stbtt.ScaleForMappingEmToPixels(&f.info, 1)))
}

// --- font slots --------------------------------------------------------------------------

// The face a font slot draws with, NO_FACE if it has none.
slot_face :: proc(font_id: u16) -> Face_Id {
	if int(font_id) >= len(fonts) { return NO_FACE }
	return fonts[font_id].face
}

// The pixel height a slot's text rasterizes at: the size in points times the raster scale,
// rounded, so each texel is one framebuffer pixel.
@(private)
slot_px :: proc(font_id: u16, font_size: u16) -> f32 {
	return max(1, math.round(f32(font_size) * raster_scale()))
}

@(private)
font_name :: proc(f: Font_Slot) -> string {
	return f.path if f.path != "" else "(from memory)"
}

@(private)
warn_font :: proc(f: Font_Slot) {
	fmt.eprintln("ui: font failed to load:", font_name(f))
}
