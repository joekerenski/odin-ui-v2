package ui

import clay "../deps/clay"
import "core:hash"
import "core:math"
import "core:strings"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"

// Rich text: a paragraph of spans in different styles (font, size, color, a box behind it,
// underline, strike, a link), wrapped together as one text.
//
// Clay wraps each text element on its own, so a paragraph lays out its own lines, at the width
// its element had last frame, and draws them as one Custom element. That lines up the
// baselines of different fonts on a line, and lets a span with a box behind it (inline code)
// take a little room on either side. A layout is kept per id while the text, fonts, sizes,
// width and options stay the same; colors and decorations can change every frame for free.
//
// Paragraphs are selectable, together: a drag selects from one paragraph to another, in the
// order they were declared, a double click a word and a triple click a paragraph; Cmd+C
// (Ctrl+C) copies, unless a text field has the keyboard. rich_selection gives the text.
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

Rich_Align :: enum u8 {
	Left,
	Center,
	Right,
}

Rich_Opts :: struct {
	line:         f32, // line height over the largest draw size on the line; 0: as text fields
	width:        f32, // the wrap width before the paragraph has one of its own; 0: the last paragraph's
	align:        Rich_Align,
	// Lines break only at newlines, and the element is as wide as the widest line (or its
	// parent, if wider): code. Clip the parent to scroll or cut what overflows.
	nowrap:       bool,
	unselectable: bool, // decoration (a list marker): no text cursor, not in a selection
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
	if laid && !opts.nowrap {
		s_rich_width = box.width
	}
	if width <= 0 {
		width = screen_w * 0.6
	}
	line := opts.line if opts.line > 0 else styles.field.line
	r := rich_layout(eid.id, spans, width, line, opts)
	res.height = r.height

	selectable := !opts.unselectable
	r.sel_lo, r.sel_hi = -1, -1
	if selectable {
		index, known := s_rich_index[eid.id]
		if !known { index = len(s_rich_order_prev) + len(s_rich_order) }
		append(&s_rich_order, eid.id)
		r.sel_lo, r.sel_hi = selection_in(eid.id, index, len(r.text))
	}

	if laid {
		// Links are hover zones: the pointer crossing one draws a frame even when idle.
		for f in r.frags {
			if r.spans[f.span].link != 0 {
				l := r.lines[f.line]
				hover_zone({box.x + f.x, box.y + l.y, f.w, l.h})
			}
		}
	}
	if laid && s_interactions_enabled {
		local := [2]f32{input.mouse_x - box.x, input.mouse_y - box.y}
		over := element_hovered(id)
		link := link_at(r, local) if over else 0
		if link != 0 {
			res.hovered = link
			request_cursor(.Hand)
			if mouse_pressed(.Left) {
				res.clicked = link
			}
		} else if selectable && over {
			request_cursor(.Text)
			if mouse_pressed(.Left) {
				select_press(eid.id, r, rich_hit(r, local))
			}
		}
		// A drag reaches every paragraph level with the pointer, however far left or right.
		if selectable && s_sel.dragging && local.y >= 0 && local.y < box.height {
			s_sel.focus = {eid.id, rich_hit(r, local)}
		}
	}

	sizing := clay.Sizing{width = clay.SizingGrow({}), height = clay.SizingFixed(r.height)}
	if opts.nowrap {
		sizing.width = clay.SizingGrow({min = r.content_w})
	}
	if clay.UI(eid)(clay.ElementDeclaration{
		layout = {sizing = sizing},
		custom = {customData = &r.custom},
	}) {}
	return
}

// The selected text, paragraphs joined by newlines; "" when nothing is selected. Temp allocated.
rich_selection :: proc() -> string {
	lo, hi, ok := selection_ends()
	if !ok { return "" }
	b := strings.builder_make(context.temp_allocator)
	for k in lo.index ..= hi.index {
		if k >= len(s_rich_order_prev) { break }
		r := s_rich[s_rich_order_prev[k]]
		if r == nil { continue }
		s := lo.at if k == lo.index else 0
		e := hi.at if k == hi.index else len(r.text)
		s, e = clamp(s, 0, len(r.text)), clamp(e, 0, len(r.text))
		if k > lo.index { strings.write_byte(&b, '\n') }
		if s < e { strings.write_string(&b, r.text[s:e]) }
	}
	return strings.to_string(b)
}

rich_select_none :: proc() {
	s_sel = {}
}

// A drag selection is under way (the host can scroll its view when the pointer nears an edge).
rich_dragging :: proc() -> bool {
	return s_sel.dragging && mouse_down(.Left)
}

// The widest line of paragraph `id` as last laid out, 0 before it has been.
rich_content_width :: proc(id: string) -> f32 {
	r := s_rich[clay.ID(id).id]
	return r.content_w if r != nil else 0
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
	content_w:    f32, // the widest line
	sel_lo:       int, // this frame's selected bytes, -1 for none
	sel_hi:       int,
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

// Selectable paragraphs in the order declared: this frame's, last frame's, and the index of
// each in last frame's (a selection's ends are ordered by it).
@(private)
s_rich_order, s_rich_order_prev: [dynamic]u32

@(private)
s_rich_index: map[u32]int

// A place in the text: a paragraph and a byte in it.
@(private)
Rich_Point :: struct {
	para: u32,
	at:   int,
}

@(private)
Rich_Selection :: struct {
	anchor, focus: Rich_Point,
	active:        bool,
	dragging:      bool,
	clicks:        int, // within a run of quick clicks: 1, 2 (word), 3 (paragraph)
	click_at:      time.Tick,
	click_pos:     [2]f32,
	claimed:       bool, // a paragraph took this frame's press
	unclaimed:     bool, // last frame's press landed on no paragraph: clear
}

@(private)
s_sel: Rich_Selection

RICH_KEEP_FRAMES :: 600

// Called from begin_layout: the paragraph order rolls over, a press last frame that no
// paragraph took clears the selection, a release ends a drag, Cmd+C copies; and now and then,
// layouts no paragraph asked for in a while go.
@(private)
rich_begin_frame :: proc() {
	s_rich_frame += 1
	s_rich_order, s_rich_order_prev = s_rich_order_prev, s_rich_order
	clear(&s_rich_order)
	clear(&s_rich_index)
	for id, k in s_rich_order_prev { s_rich_index[id] = k }

	if s_sel.unclaimed {
		s_sel = {click_at = s_sel.click_at, click_pos = s_sel.click_pos}
	}
	s_sel.unclaimed = mouse_pressed(.Left) && s_sel.active
	if !mouse_down(.Left) {
		s_sel.dragging = false
	}
	if PRIMARY_MOD in input.mods && key_pressed(.C) && !editing() {
		if text := rich_selection(); text != "" {
			set_clipboard(text)
		}
	}

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
	delete(s_rich_order)
	delete(s_rich_order_prev)
	delete(s_rich_index)
	s_rich, s_rich_order, s_rich_order_prev, s_rich_index = nil, nil, nil, nil
	s_sel = {}
}

@(private)
rich_free :: proc(r: ^Rich_Layout) {
	delete(r.text)
	delete(r.spans)
	delete(r.frags)
	delete(r.lines)
	free(r)
}

// --- selection -----------------------------------------------------------------------------

// A press on a paragraph: a click places the selection's start, a double click takes the
// word, a triple click the paragraph, Shift+click extends.
@(private = "file")
select_press :: proc(id: u32, r: ^Rich_Layout, at: int) {
	quick := time.duration_seconds(time.tick_since(s_sel.click_at)) < 0.4
	near := abs(input.mouse_x - s_sel.click_pos.x) < 4 && abs(input.mouse_y - s_sel.click_pos.y) < 4
	s_sel.clicks = s_sel.clicks % 3 + 1 if quick && near else 1
	s_sel.click_at = time.tick_now()
	s_sel.click_pos = {input.mouse_x, input.mouse_y}
	s_sel.claimed = true
	s_sel.unclaimed = false
	extend := .Shift in input.mods && s_sel.active
	s_sel.active = true
	switch s_sel.clicks {
	case 1:
		if !extend { s_sel.anchor = {id, at} }
		s_sel.focus = {id, at}
		s_sel.dragging = true
	case 2:
		lo, hi := word_bounds(r.text, at)
		s_sel.anchor, s_sel.focus = {id, lo}, {id, hi}
	case 3:
		s_sel.anchor, s_sel.focus = {id, 0}, {id, len(r.text)}
	}
}

@(private = "file")
Rich_End :: struct {
	index: int,
	at:    int,
}

// The selection's ends in paragraph order, start first; false when there is none.
@(private = "file")
selection_ends :: proc() -> (lo, hi: Rich_End, ok: bool) {
	if !s_sel.active { return }
	ia, ka := s_rich_index[s_sel.anchor.para]
	ib, kb := s_rich_index[s_sel.focus.para]
	if !ka || !kb { return }
	a, b := Rich_End{ia, s_sel.anchor.at}, Rich_End{ib, s_sel.focus.at}
	if b.index < a.index || (b.index == a.index && b.at < a.at) { a, b = b, a }
	if a == b { return }
	return a, b, true
}

// The bytes of paragraph `id` (at `index` in the order) inside the selection; -1, -1 if none.
@(private = "file")
selection_in :: proc(id: u32, index, n: int) -> (int, int) {
	lo, hi, ok := selection_ends()
	if !ok || index < lo.index || index > hi.index { return -1, -1 }
	s := lo.at if index == lo.index else 0
	e := hi.at if index == hi.index else n
	return s, e
}

// The word (letters, digits, '_') or other run around byte `at`.
@(private = "file")
word_bounds :: proc(s: string, at: int) -> (int, int) {
	is_word :: proc(r: rune) -> bool { return unicode.is_letter(r) || unicode.is_digit(r) || r == '_' }
	at := clamp(at, 0, len(s))
	if at == len(s) && at > 0 { at -= 1 }
	if len(s) == 0 { return 0, 0 }
	r0, _ := utf8.decode_rune_in_string(s[at:])
	kind := is_word(r0)
	lo := at
	for lo > 0 {
		r, n := utf8.decode_last_rune_in_string(s[:lo])
		if is_word(r) != kind || r == '\n' { break }
		lo -= n
	}
	hi := at
	for hi < len(s) {
		r, n := utf8.decode_rune_in_string(s[hi:])
		if is_word(r) != kind || r == '\n' { break }
		hi += n
	}
	return lo, hi
}

// The link under a point in the paragraph, 0 for none.
@(private = "file")
link_at :: proc(r: ^Rich_Layout, local: [2]f32) -> int {
	for f in r.frags {
		link := r.spans[f.span].link
		l := r.lines[f.line]
		if link != 0 && local.x >= f.x && local.x < f.x + f.w && local.y >= l.y && local.y < l.y + l.h {
			return link
		}
	}
	return 0
}

// The byte boundary nearest a point: on its line (above the first: the first; below the last:
// the last), between the characters it falls between.
@(private = "file")
rich_hit :: proc(r: ^Rich_Layout, local: [2]f32) -> int {
	if len(r.lines) == 0 || len(r.frags) == 0 { return 0 }
	ln := len(r.lines) - 1
	for l, k in r.lines {
		if local.y < l.y + l.h {
			ln = k
			break
		}
	}
	first, last := -1, -1
	for f, k in r.frags {
		if f.line != ln { continue }
		if first < 0 { first = k }
		last = k
	}
	if first < 0 {
		// An empty line: the end of the text before it.
		for k := len(r.frags) - 1; k >= 0; k -= 1 {
			if r.frags[k].line < ln { return r.frags[k].end }
		}
		return 0
	}
	if local.x <= r.frags[first].x { return r.frags[first].start }
	for k in first ..= last {
		f := r.frags[k]
		if local.x >= f.x + f.w { continue }
		st := r.spans[f.span]
		x := f.x + f.pad_l
		i := f.start
		for i < f.end {
			ch, n := utf8.decode_rune_in_string(r.text[i:f.end])
			adv := rune_width(ch, st.font, st.size)
			if local.x < x + adv * 0.5 { return i }
			x += adv
			i += n
		}
		return f.end
	}
	return r.frags[last].end
}

// --- layout --------------------------------------------------------------------------------

// What the layout depends on: the texts, the fonts and sizes, which spans have boxes, the
// width (unless it doesn't wrap), the raster scale (advances are rounded in pixels), the line
// height and the alignment.
@(private)
rich_key :: proc(spans: []Span, width, line: f32, opts: Rich_Opts) -> u64 {
	h: u64 = 0xcbf29ce484222325
	mix :: proc(h: u64, data: []byte) -> u64 { return hash.fnv64a(data, h) }
	for s in spans {
		h = mix(h, transmute([]byte)s.text)
		meta := [4]u32{u32(s.style.font), u32(s.style.size), u32(slot_face(s.style.font)), u32(s.style.bg[3] > 0)}
		h = mix(h, transmute([]byte)meta[:])
	}
	nums := [5]f32{0 if opts.nowrap else width, raster_scale(), line, f32(opts.align), f32(int(opts.nowrap))}
	return mix(h, transmute([]byte)nums[:])
}

@(private)
rich_layout :: proc(id: u32, spans: []Span, width, line: f32, opts: Rich_Opts) -> ^Rich_Layout {
	key := rich_key(spans, width, line, opts)
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
	wrap_spans(r, starts, max(f32) if opts.nowrap else width, line)
	if !opts.nowrap && opts.align != .Left {
		align_lines(r, width, opts.align)
	}
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
// than the whole line breaks between characters. Spaces where a line wraps hang (they take no
// room); spaces after a newline stay (indentation), and a newline breaks the line.
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
	wrapped := false // the line began at a wrap, not a newline
	pending := -1 // a space atom waiting for the word after it
	i := 0
	for i < len(atoms) {
		a := atoms[i]
		switch a.kind {
		case .Newline:
			ln, x, pending, wrapped = ln + 1, 0, -1, false
			i += 1
			continue
		case .Space:
			if x > 0 {
				pending = i
			} else if !wrapped {
				x = place(r, a, ln, x)
			}
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
			ln, x, pending, wrapped = ln + 1, 0, -1, true
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
	r.content_w = 0
	for f in r.frags {
		line_fit(&r.lines[f.line], r.spans[f.span], line)
		r.content_w = max(r.content_w, f.x + f.w)
	}
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

// Moves each line's frags right by its free room (all of it, or half).
@(private = "file")
align_lines :: proc(r: ^Rich_Layout, width: f32, align: Rich_Align) {
	ends := make([]f32, len(r.lines), context.temp_allocator)
	for f in r.frags { ends[f.line] = max(ends[f.line], f.x + f.w) }
	for &f in r.frags {
		room := max(0, width - ends[f.line])
		f.x += room * 0.5 if align == .Center else room
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

// A span's text width in layout units, as draw_text draws it.
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

// --- drawing -------------------------------------------------------------------------------

// Draws a laid-out paragraph in its element's box (dispatch_custom): the selection behind
// everything, then each frag's box, text and lines.
@(private)
draw_rich :: proc(r: ^Rich_Layout, box: clay.BoundingBox) {
	r.used = s_rich_frame
	if r.sel_lo >= 0 {
		draw_selection(r, box)
	}
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

// The selected part of each frag, the height of its line.
@(private = "file")
draw_selection :: proc(r: ^Rich_Layout, box: clay.BoundingBox) {
	color := styles.field.selection
	for f in r.frags {
		s, e := max(f.start, r.sel_lo), min(f.end, r.sel_hi)
		if s >= e { continue }
		st := r.spans[f.span]
		l := r.lines[f.line]
		x0 := f.x + f.pad_l + text_width(r.text[f.start:s], st.font, st.size)
		x1 := f.x + f.pad_l + text_width(r.text[f.start:e], st.font, st.size)
		if s == f.start { x0 = f.x }
		if e == f.end { x1 = f.x + f.w }
		draw_round_rect({box.x + x0, box.y + l.y, x1 - x0, l.h}, {}, color)
	}
}

@(private = "file")
fill_line :: proc(x, y, w, t: f32, c: Color) {
	draw_round_rect({x, y, w, t}, {}, c)
}
