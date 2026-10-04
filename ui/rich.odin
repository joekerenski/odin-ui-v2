package ui

import clay "../deps/clay"
import "core:hash"
import "core:math"
import "core:strings"
import "core:unicode/utf8"

// Rich text: a paragraph of spans in different styles (font, size, color, a box behind it,
// underline, strike, a link), wrapped together as one text.
//
// Clay wraps each text element on its own, so a paragraph lays out its own lines, at the width
// its element had last frame, and draws them as one Custom element. That lines up the
// baselines of different fonts on a line, and lets a span with a box behind it (inline code)
// take a little room on either side. A layout is kept per id while the text, fonts, sizes and
// width stay the same; colors and decorations can change every frame for free.
//
//   spans := []ui.Span{
//       {"Plain, ", {font = BODY, size = 19, color = ui.theme.text}},
//       {"italic", {font = ITALIC, size = 19, color = ui.theme.text}},
//       {" and a ", {font = BODY, size = 19, color = ui.theme.text}},
//       {"link", {font = BODY, size = 19, color = ui.theme.accent, underline = true, link = 1}},
//   }
//   r := ui.rich_text("para", spans)
//   if r.clicked == 1 { ... }

Span_Style :: struct {
	font:      u16,
	size:      u16,
	color:     Color,
	bg:        Color, // a rounded box behind the span (inline code); alpha 0: none
	underline: bool,
	strike:    bool,
	link:      int, // non-zero: rich_text reports the span hovered and clicked
}

Span :: struct {
	text:  string,
	style: Span_Style,
}

Rich_Opts :: struct {
	line:  f32, // line height over the largest draw size on the line; 0: as text fields
	width: f32, // the wrap width before the paragraph has one of its own; 0: the last paragraph's
}

Rich_Result :: struct {
	height:  f32,
	hovered: int, // the link under the pointer, 0 for none
	clicked: int, // the link pressed this frame
}

// Room a box behind a span takes on either side, and its corner radius, in layout units.
RICH_BOX_PAD :: 3
RICH_BOX_RADIUS :: 3

// A paragraph. The element grows to its parent's width; its height is its lines'.
rich_text :: proc(id: string, spans: []Span, opts := Rich_Opts{}) -> (res: Rich_Result) {
	eid := clay.ID(id)
	box, laid := element_box(id)
	width := box.width if laid else (opts.width if opts.width > 0 else s_rich_width)
	if laid {
		s_rich_width = box.width
	}
	if width <= 0 {
		width = screen_w * 0.6
	}
	line := opts.line if opts.line > 0 else styles.field.line
	r := rich_layout(eid.id, spans, width, line)
	res.height = r.height

	if laid && s_interactions_enabled && element_hovered(id) {
		local := [2]f32{input.mouse_x - box.x, input.mouse_y - box.y}
		for f in r.frags {
			link := r.spans[f.span].link
			l := r.lines[f.line]
			if link != 0 && local.x >= f.x && local.x < f.x + f.w && local.y >= l.y && local.y < l.y + l.h {
				res.hovered = link
				request_cursor(.Hand)
				if mouse_pressed(.Left) {
					res.clicked = link
				}
				break
			}
		}
	}

	if clay.UI(eid)(clay.ElementDeclaration{
		layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(r.height)}},
		custom = {customData = &r.custom},
	}) {}
	return
}

// A laid-out paragraph. Its Custom_Data comes first, so the pointer Clay carries is both.
@(private)
Rich_Layout :: struct {
	using custom: Custom_Data,
	key:          u64,
	used:         u64, // frame last laid out or drawn
	text:         string, // the spans' texts, concatenated: frags index into it
	spans:        [dynamic]Span_Style,
	frags:        [dynamic]Rich_Frag,
	lines:        [dynamic]Rich_Line,
	height:       f32,
}

// A run of one span on one line.
@(private)
Rich_Frag :: struct {
	span:       int,
	line:       int,
	start, end: int, // in Rich_Layout.text
	x, w:       f32, // w includes the box's room
	pad_l:      f32, // the box's room before the text
}

@(private)
Rich_Line :: struct {
	y, h, baseline: f32,
}

@(private)
s_rich: map[u32]^Rich_Layout

@(private)
s_rich_frame: u64

@(private)
s_rich_width: f32

RICH_KEEP_FRAMES :: 600

// Called from begin_layout: drops layouts no paragraph asked for in a while.
@(private)
rich_begin_frame :: proc() {
	s_rich_frame += 1
	if s_rich_frame % 120 != 0 {
		return
	}
	for id, r in s_rich {
		if s_rich_frame - r.used > RICH_KEEP_FRAMES {
			rich_free(r)
			delete_key(&s_rich, id)
		}
	}
}

@(private)
rich_teardown :: proc() {
	for _, r in s_rich {
		rich_free(r)
	}
	delete(s_rich)
	s_rich = nil
}

@(private)
rich_free :: proc(r: ^Rich_Layout) {
	delete(r.text)
	delete(r.spans)
	delete(r.frags)
	delete(r.lines)
	free(r)
}

// What the layout depends on: the texts, the fonts and sizes, which spans have boxes, the
// width, the raster scale (advances are rounded in pixels) and the line height.
@(private)
rich_key :: proc(spans: []Span, width, line: f32) -> u64 {
	h: u64 = 0xcbf29ce484222325
	mix :: proc(h: u64, data: []byte) -> u64 { return hash.fnv64a(data, h) }
	for s in spans {
		h = mix(h, transmute([]byte)s.text)
		meta := [4]u32{u32(s.style.font), u32(s.style.size), u32(slot_face(s.style.font)), u32(s.style.bg[3] > 0)}
		h = mix(h, transmute([]byte)meta[:])
	}
	nums := [3]f32{width, raster_scale(), line}
	return mix(h, transmute([]byte)nums[:])
}

@(private)
rich_layout :: proc(id: u32, spans: []Span, width, line: f32) -> ^Rich_Layout {
	key := rich_key(spans, width, line)
	r := s_rich[id]
	if r == nil {
		r = new(Rich_Layout)
		r.kind = .Rich
		s_rich[id] = r
	}
	r.used = s_rich_frame
	if r.key == key && len(r.spans) == len(spans) {
		for s, k in spans { r.spans[k] = s.style }
		return r
	}
	r.key = key
	clear(&r.spans)
	clear(&r.frags)
	clear(&r.lines)
	delete(r.text)
	b := strings.builder_make()
	starts := make([]int, len(spans) + 1, context.temp_allocator)
	for s, k in spans {
		starts[k] = strings.builder_len(b)
		strings.write_string(&b, s.text)
		append(&r.spans, s.style)
	}
	starts[len(spans)] = strings.builder_len(b)
	r.text = strings.to_string(b)
	wrap_spans(r, starts, width, line)
	return r
}

// Pieces of the text between break chances: a word part (one span's share of a word), a run of
// spaces, or a newline.
@(private = "file")
Atom :: struct {
	span:       int,
	start, end: int,
	w, pad_l:   f32,
	kind:       Atom_Kind,
}

@(private = "file")
Atom_Kind :: enum u8 { Word, Space, Newline }

// Greedy wrapping: a word goes on the line if it fits, else starts the next one; a word wider
// than the whole line breaks between characters. Spaces where a line breaks hang (they take no
// room), and a newline breaks the line.
@(private = "file")
wrap_spans :: proc(r: ^Rich_Layout, starts: []int, width, line: f32) {
	atoms := make([dynamic]Atom, context.temp_allocator)
	for k in 0 ..< len(r.spans) {
		st := r.spans[k]
		pad: f32 = RICH_BOX_PAD if st.bg[3] > 0 else 0
		s, e := starts[k], starts[k + 1]
		i := s
		for i < e {
			c := r.text[i]
			j := i + 1
			kind := Atom_Kind.Word
			switch c {
			case '\n':
				kind = .Newline
			case ' ':
				kind = .Space
				for j < e && r.text[j] == ' ' { j += 1 }
			case:
				for j < e && r.text[j] != ' ' && r.text[j] != '\n' { j += 1 }
			}
			a := Atom{span = k, start = i, end = j, kind = kind}
			if kind != .Newline {
				a.w = span_width(r.text[i:j], st)
			}
			if i == s { a.pad_l = pad }
			a.w += a.pad_l
			if j == e { a.w += pad }
			append(&atoms, a)
			i = j
		}
	}

	ln := 0
	x: f32
	pending := -1 // a space atom waiting for the word after it
	i := 0
	for i < len(atoms) {
		a := atoms[i]
		switch a.kind {
		case .Newline:
			ln, x, pending = ln + 1, 0, -1
			i += 1
			continue
		case .Space:
			if x > 0 { pending = i }
			i += 1
			continue
		case .Word:
		}
		// The whole word: word parts with nothing between them.
		j := i
		ww: f32
		for j < len(atoms) && atoms[j].kind == .Word {
			ww += atoms[j].w
			j += 1
		}
		space: f32 = atoms[pending].w if pending >= 0 else 0
		if x > 0 && x + space + ww > width {
			ln, x, pending = ln + 1, 0, -1
		}
		if pending >= 0 {
			x = place(r, atoms[pending], ln, x)
			pending = -1
		}
		for k in i ..< j {
			if x == 0 && ww > width {
				// Alone and still too wide: break it between characters.
				x, ln = place_by_char(r, atoms[k], ln, x, width)
			} else {
				x = place(r, atoms[k], ln, x)
			}
		}
		i = j
	}

	// Line boxes: the tallest line height on the line, and one baseline for all, as each
	// span would center its text in its own line height.
	n := ln + 1
	resize(&r.lines, n)
	for &l in r.lines { l = {} }
	base := r.spans[0] if len(r.spans) > 0 else Span_Style{font = theme.font_body, size = theme.size_body}
	for k in 0 ..< n { line_fit(&r.lines[k], base, line) }
	for f in r.frags { line_fit(&r.lines[f.line], r.spans[f.span], line) }
	y: f32
	for &l in r.lines {
		l.y = y
		y += l.h
	}
	r.height = y
	if len(r.frags) == 0 && strings.trim_space(r.text) == "" {
		r.height = 0
	}
}

// The line box for a style, folded into l.
@(private = "file")
line_fit :: proc(l: ^Rich_Line, st: Span_Style, line: f32) {
	h := text_draw_size(st.font, st.size)
	lh := math.round(h * line)
	l.h = max(l.h, lh)
	l.baseline = max(l.baseline, (lh - h) * 0.5 + span_ascent(st))
}

// Appends an atom to the line, joining the previous frag when it's the same span and adjacent.
@(private = "file")
place :: proc(r: ^Rich_Layout, a: Atom, ln: int, x: f32) -> f32 {
	if n := len(r.frags); n > 0 {
		f := &r.frags[n - 1]
		if f.span == a.span && f.line == ln && f.end == a.start {
			f.end = a.end
			f.w += a.w
			return x + a.w
		}
	}
	append(&r.frags, Rich_Frag{span = a.span, line = ln, start = a.start, end = a.end, x = x, w = a.w, pad_l = a.pad_l})
	return x + a.w
}

// A word part one character at a time, breaking the line where the next one doesn't fit.
@(private = "file")
place_by_char :: proc(r: ^Rich_Layout, a: Atom, ln: int, x: f32, width: f32) -> (f32, int) {
	st := r.spans[a.span]
	pad_r := a.w - a.pad_l - span_width(r.text[a.start:a.end], st)
	x, ln := x, ln
	i := a.start
	for i < a.end {
		ch, n := utf8.decode_rune_in_string(r.text[i:a.end])
		part := Atom{span = a.span, start = i, end = i + n, kind = .Word}
		part.w = rune_width(ch, st.font, st.size)
		if i == a.start {
			part.pad_l = a.pad_l
			part.w += a.pad_l
		}
		if i + n == a.end { part.w += pad_r }
		if x > 0 && x + part.w > width {
			ln, x = ln + 1, 0
		}
		x = place(r, part, ln, x)
		i += n
	}
	return x, ln
}

// A span's text width in layout units, as draw_run draws it.
@(private)
span_width :: proc(s: string, st: Span_Style) -> f32 {
	return text_width(s, st.font, st.size)
}

@(private)
span_ascent :: proc(st: Span_Style) -> f32 {
	face := slot_face(st.font)
	if face == NO_FACE {
		return f32(st.size) * 0.8
	}
	px := slot_px(st.font, st.size)
	return f32(face_ascent(face)) * face_scale(face, px) / raster_scale()
}

// Draws a laid-out paragraph in its element's box (dispatch_custom).
@(private)
draw_rich :: proc(r: ^Rich_Layout, box: clay.BoundingBox) {
	r.used = s_rich_frame
	for f in r.frags {
		st := r.spans[f.span]
		l := r.lines[f.line]
		baseline := box.y + l.y + l.baseline
		asc := span_ascent(st)
		h := text_draw_size(st.font, st.size)
		x := box.x + f.x
		text := r.text[f.start:f.end]
		if st.bg[3] > 0 {
			draw_round_rect({x, baseline - asc - 1, f.w, h + 2}, {RICH_BOX_RADIUS, RICH_BOX_RADIUS, RICH_BOX_RADIUS, RICH_BOX_RADIUS}, st.bg)
		}
		tx := x + f.pad_l
		draw_text(text, tx, baseline - asc, st.font, st.size, st.color)
		if st.underline || st.strike {
			w := text_width(strings.trim_right(text, " "), st.font, st.size)
			t := max(1 / raster_scale(), f32(st.size) * 0.06)
			if st.underline {
				fill_line(tx, snap_px(baseline + f32(st.size) * 0.1), w, t, st.color)
			}
			if st.strike {
				fill_line(tx, snap_px(baseline - f32(st.size) * 0.27), w, t, st.color)
			}
		}
	}
}

@(private = "file")
fill_line :: proc(x, y, w, t: f32, c: Color) {
	draw_round_rect({x, y, w, t}, {}, c)
}

