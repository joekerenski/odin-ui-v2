package ui

import clay "../deps/clay"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Text fields: one line, or many that wrap and grow to a few lines before
// they scroll. The host owns the state and reads the text back:
//
//   @(static) draft: ui.Text_Edit
//   r := ui.text_edit("Draft", &draft, {multiline = true, enter_submits = true, placeholder = "Say something"})
//   if r.submitted { send(ui.edit_text(&draft)); ui.edit_clear(&draft) }
//
// Keys follow the platform. On macOS Option moves by word and Cmd by line,
// Cmd+Up/Down to either end; elsewhere Ctrl moves by word, Home/End by line
// and Ctrl+Home/End to either end. A one-line field leaves Up, Down and the
// page keys to the host, for a list under a search field. Cmd (Ctrl) with A, C, X, V, Z selects
// all, copies, cuts, pastes and undoes; Shift+Cmd+Z (Ctrl+Y) redoes. A
// double click selects a word, a triple click the line.
//
// The field lays out its own lines with the same advances Clay measures, and
// draws each line as text runs: the selected run on the selection color, the
// caret as the left edge of the run after it. No floating layers, so a field
// inside a floating window stacks with it.

Text_Edit :: struct {
	buf:        [dynamic]u8,
	// Byte offsets on rune boundaries. The selection runs between them,
	// either way round; it is empty when they are equal.
	caret:      int,
	anchor:     int,
	want_x:     Maybe(f32), // the column Up and Down keep
	scroll:     [2]f32,
	undo:       [dynamic]Edit_Snapshot,
	redo:       [dynamic]Edit_Snapshot,
	last_kind:  Edit_Kind,
	last_time:  f64,
	clicks:     int, // within a run of quick clicks: 1, 2 (word), 3 (line)
	click_time: f64,
	click_pos:  [2]f32,
	follow:     bool, // scroll the caret into view
}

Edit_Snapshot :: struct {
	text:   string,
	caret:  int,
	anchor: int,
}

Edit_Kind :: enum u8 {
	None,
	Type,
	Delete,
	Other,
}

Edit_Opts :: struct {
	multiline:     bool,
	lines:         int, // lines a multiline field grows to before it scrolls; 0 = 6
	enter_submits: bool, // multiline: Enter submits, Shift+Enter breaks the line
	placeholder:   string,
	font:          Maybe(u16), // default the body font
	size:          u16, // default the body size
	width:         f32, // 0 = grow
	bare:          bool, // no background, border or padding
}

Edit_Result :: struct {
	changed:   bool, // the text changed this frame
	submitted: bool, // Enter on one line, or with enter_submits
	cancelled: bool, // Escape while focused
}

UNDO_MAX :: 200

// --- focus ---------------------------------------------------------------------------
//
// One field has the keyboard at a time. A click on a field focuses it, a
// click anywhere else blurs it, and a focused field that stops being built
// lets go the next frame.

@(private)
s_focus: u32

@(private)
s_focus_frame: u64

@(private)
s_edit_clock: f64

@(private)
s_blink_from: f64

focus :: proc(id: string) {
	s_focus = clay.ID(id).id
	s_focus_frame = s_frame
	s_blink_from = s_edit_clock
}

blur :: proc() {
	s_focus = 0
}

focused :: proc(id: string) -> bool {
	return s_focus != 0 && s_focus == clay.ID(id).id
}

// Some field has the keyboard: skip bare-key shortcuts while it does.
editing :: proc() -> bool {
	return s_focus != 0
}

// Called by `frame`, after the frame stamp moves.
@(private)
edit_tick :: proc() {
	s_edit_clock += f64(frame_dt)
	if s_focus != 0 && s_focus_frame + 1 < s_frame {
		s_focus = 0
	}
}

// --- state -----------------------------------------------------------------------------

edit_text :: proc(e: ^Text_Edit) -> string {
	return string(e.buf[:])
}

// Replace the whole text (undoable) and put the caret at its end.
edit_set :: proc(e: ^Text_Edit, s: string) {
	remember(e, .Other)
	clear(&e.buf)
	append(&e.buf, s)
	e.caret, e.anchor = len(e.buf), len(e.buf)
	e.want_x = nil
	e.follow = true
	e.last_kind = .None
}

edit_clear :: proc(e: ^Text_Edit) {
	edit_set(e, "")
}

edit_select_all :: proc(e: ^Text_Edit) {
	e.anchor, e.caret = 0, len(e.buf)
}

// The selected text, a view into the buffer.
edit_selection :: proc(e: ^Text_Edit) -> string {
	lo, hi := min(e.caret, e.anchor), max(e.caret, e.anchor)
	return string(e.buf[lo:hi])
}

edit_destroy :: proc(e: ^Text_Edit) {
	free_snapshots(&e.undo)
	free_snapshots(&e.redo)
	delete(e.undo)
	delete(e.redo)
	delete(e.buf)
	e^ = {}
}

// --- the widget ------------------------------------------------------------------------

text_edit :: proc(id: string, e: ^Text_Edit, opts: Edit_Opts = {}) -> (res: Edit_Result) {
	st := styles.field
	ed := Editor {
		e         = e,
		font      = opts.font.? or_else theme.font_body,
		size      = opts.size if opts.size != 0 else theme.size_body,
		multiline = opts.multiline,
	}
	ed.line_h = math.round(text_draw_size(ed.font, ed.size) * st.line)
	max_lines := opts.multiline ? (opts.lines if opts.lines > 0 else 6) : 1
	vp_id := fmt.tprintf("%s_vp", id)

	// The host may have changed buf directly.
	e.caret = snap_rune(edit_text(e), clamp(e.caret, 0, len(e.buf)))
	e.anchor = snap_rune(edit_text(e), clamp(e.anchor, 0, len(e.buf)))

	// Lines as drawn last frame: what the pointer and Up/Down act on.
	vp, vp_ok := element_box(vp_id)
	ed.wrap_w = vp.width if vp_ok else 0
	relayout(&ed)

	hot := s_interactions_enabled && hovered(id)
	if hot {
		request_cursor(.Text)
	}
	has_focus := focused(id)
	if mouse_pressed(.Left) {
		if hot && !has_focus {
			focus(id)
			has_focus = true
		} else if !hot && has_focus {
			blur()
			has_focus = false
		}
	}
	dragging := drag_update(id)

	text_before := len(e.buf)
	caret_before, anchor_before := e.caret, e.anchor
	if has_focus {
		s_focus_frame = s_frame
		if vp_ok {
			edit_pointer(&ed, vp, hot, dragging)
		}
		res = edit_keys(&ed, opts)
		if hot && opts.multiline && input.wheel_y != 0 {
			e.scroll.y -= input.wheel_y * ed.line_h
		}
	}
	if res.changed || len(e.buf) != text_before {
		res.changed = true
		relayout(&ed)
	}
	if res.changed || e.caret != caret_before || e.anchor != anchor_before {
		s_blink_from = s_edit_clock
	}

	// Scroll: the caret into view after it moved, then within the content.
	vis := clamp(len(ed.lines), 1, max_lines)
	view_h := f32(vis) * ed.line_h
	view_w := vp.width if vp_ok else 0
	text := edit_text(e)
	if e.follow {
		k := line_of(ed.lines[:], e.caret)
		if opts.multiline {
			y := f32(k) * ed.line_h
			e.scroll.y = min(e.scroll.y, y)
			e.scroll.y = max(e.scroll.y, y + ed.line_h - view_h)
		} else if view_w > 0 {
			x := text_width(text[:e.caret], ed.font, ed.size)
			margin := f32(ed.size)
			e.scroll.x = min(e.scroll.x, x - margin)
			e.scroll.x = max(e.scroll.x, x + margin - view_w)
		}
		e.follow = false
	}
	content_h := f32(len(ed.lines)) * ed.line_h
	e.scroll.y = clamp(e.scroll.y, 0, max(0, content_h - view_h)) if opts.multiline else 0
	content_w := text_width(text, ed.font, ed.size) + 2
	e.scroll.x = clamp(e.scroll.x, 0, max(0, content_w - view_w)) if !opts.multiline else 0

	// Draw.
	pad_x, pad_y: u16 = st.pad_x, st.pad_y
	if opts.bare {
		pad_x, pad_y = 0, 0
	}
	bg, border: Color
	if !opts.bare {
		bg = feedback(id, st.bg, st.bg_hover, hot && !has_focus, false)
		border = st.border_focus if has_focus else st.border
	}
	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {
			sizing  = {width = clay.SizingFixed(opts.width) if opts.width > 0 else clay.SizingGrow({}), height = clay.SizingFit({})},
			padding = {pad_x, pad_x, pad_y, pad_y},
		},
		backgroundColor = bg,
		cornerRadius    = clay.CornerRadiusAll(st.radius),
		border          = {color = border, width = clay.BorderWidth{} if opts.bare else clay.BorderWidth{1, 1, 1, 1, 0}},
	}) {
		if clay.UI(clay.ID(vp_id))(clay.ElementDeclaration{
			layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(view_h)}},
			clip   = {horizontal = true, vertical = true, childOffset = {-e.scroll.x, -e.scroll.y}},
		}) {
			if clay.UI()(clay.ElementDeclaration{
				layout = {
					sizing          = {width = clay.SizingGrow({}), height = clay.SizingFixed(content_h)},
					layoutDirection = .TopToBottom,
				},
			}) {
				blink := int((s_edit_clock - s_blink_from) / 0.53) % 2 == 0
				show_caret := has_focus && e.caret == e.anchor && blink
				first := clamp(int(e.scroll.y / ed.line_h), 0, len(ed.lines) - 1)
				last := min(len(ed.lines), first + vis + 2)
				if first > 0 {
					if clay.UI()(clay.ElementDeclaration{
						layout = {sizing = {height = clay.SizingFixed(f32(first) * ed.line_h)}},
					}) {}
				}
				for k in first ..< last {
					draw_line(&ed, k, show_caret, has_focus, opts.placeholder)
				}
			}
		}
	}
	return
}

// --- layout ----------------------------------------------------------------------------

@(private = "file")
Editor :: struct {
	e:         ^Text_Edit,
	font:      u16,
	size:      u16,
	line_h:    f32,
	wrap_w:    f32,
	multiline: bool,
	lines:     [dynamic]Line,
}

// A visual line: [start, end) of the buffer, without its '\n'. A line
// broken by wrapping ends where the next starts.
@(private = "file")
Line :: struct {
	start, end: int,
}

@(private = "file")
relayout :: proc(ed: ^Editor) {
	if ed.lines == nil {
		ed.lines = make([dynamic]Line, context.temp_allocator)
	}
	wrap(edit_text(ed.e), ed.font, ed.size, ed.wrap_w if ed.multiline else 0, &ed.lines)
}

// Break at '\n', and when max_w > 0 after the last space that fits (or
// mid-word when a word alone is too wide). Spaces may hang past the edge.
@(private = "file")
wrap :: proc(s: string, font, size: u16, max_w: f32, out: ^[dynamic]Line) {
	clear(out)
	para := 0
	for {
		nl := strings.index_byte(s[para:], '\n')
		pend := len(s) if nl < 0 else para + nl
		start := para
		if max_w > 0 {
			x: f32
			brk := -1
			i := para
			for i < pend {
				r, w := utf8.decode_rune_in_string(s[i:pend])
				adv := rune_width(r, font, size)
				if r != ' ' && x + adv > max_w && i > start {
					end := brk if brk > start else i
					append(out, Line{start, end})
					start, i, x, brk = end, end, 0, -1
					continue
				}
				x += adv
				i += w
				if r == ' ' {
					brk = i
				}
			}
		}
		append(out, Line{start, pend})
		if nl < 0 {
			break
		}
		para = pend + 1
	}
}

// The line showing offset i: at a wrap, the start of the next line.
@(private = "file")
line_of :: proc(lines: []Line, i: int) -> int {
	lo, hi := 0, len(lines) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if lines[mid].start <= i {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo
}

// Where a caret placed at a line's end goes: before its last character when
// the line wraps, or it would show at the start of the next line.
@(private = "file")
line_end :: proc(ed: ^Editor, k: int) -> int {
	l := ed.lines[k]
	if k + 1 < len(ed.lines) && ed.lines[k + 1].start == l.end && l.end > l.start {
		return prev_rune(edit_text(ed.e), l.end)
	}
	return l.end
}

@(private = "file")
index_at_x :: proc(ed: ^Editor, k: int, x: f32) -> int {
	s := edit_text(ed.e)
	l := ed.lines[k]
	cx: f32
	i := l.start
	for i < l.end {
		r, w := utf8.decode_rune_in_string(s[i:l.end])
		adv := rune_width(r, ed.font, ed.size)
		if x < cx + adv * 0.5 {
			return i
		}
		cx += adv
		i += w
	}
	return line_end(ed, k)
}

@(private = "file")
x_of :: proc(ed: ^Editor, i: int) -> f32 {
	l := ed.lines[line_of(ed.lines[:], i)]
	return text_width(edit_text(ed.e)[l.start:i], ed.font, ed.size)
}

// --- input -----------------------------------------------------------------------------

@(private = "file")
edit_pointer :: proc(ed: ^Editor, vp: clay.BoundingBox, hot, dragging: bool) {
	e := ed.e
	local := [2]f32{input.mouse_x - vp.x + e.scroll.x, input.mouse_y - vp.y + e.scroll.y}
	k := clamp(int(math.floor(local.y / ed.line_h)), 0, len(ed.lines) - 1)
	at := index_at_x(ed, k, local.x)
	s := edit_text(e)
	if mouse_pressed(.Left) && hot {
		quick := s_edit_clock - e.click_time < 0.4
		near := abs(input.mouse_x - e.click_pos.x) < 4 && abs(input.mouse_y - e.click_pos.y) < 4
		e.clicks = e.clicks % 3 + 1 if quick && near else 1
		e.click_time = s_edit_clock
		e.click_pos = {input.mouse_x, input.mouse_y}
		switch e.clicks {
		case 1:
			e.caret = at
			if .Shift not_in input.mods {
				e.anchor = at
			}
		case 2:
			e.anchor, e.caret = word_at(s, at)
		case 3:
			e.anchor, e.caret = hard_line_at(s, at)
		}
		e.want_x = nil
		e.last_kind = .None
		e.follow = true
	} else if dragging && e.clicks == 1 {
		if at != e.caret {
			e.caret = at
			e.follow = true
		}
	}
}

@(private = "file")
edit_keys :: proc(ed: ^Editor, opts: Edit_Opts) -> (res: Edit_Result) {
	e := ed.e
	mods := input.mods
	shift := .Shift in mods
	cmd := PRIMARY_MOD in mods
	when ODIN_OS == .Darwin {
		word := .Alt in mods
		by_line := .Super in mods
	} else {
		word := .Ctrl in mods
		by_line := false
	}
	lo, hi := min(e.caret, e.anchor), max(e.caret, e.anchor)
	has_sel := lo != hi
	k := line_of(ed.lines[:], e.caret)

	if cmd {
		if key_pressed(.A) {
			edit_select_all(e)
		}
		if key_pressed(.C) && has_sel {
			set_clipboard(edit_selection(e))
		}
		if key_pressed(.X) && has_sel {
			set_clipboard(edit_selection(e))
			remember(e, .Other)
			replace(e, lo, hi, "")
			res.changed = true
		}
		if key_repeat(.V) {
			if paste := clean_paste(get_clipboard(), opts.multiline); paste != "" {
				remember(e, .Other)
				replace(e, lo, hi, paste)
				res.changed = true
			}
		}
		when ODIN_OS == .Darwin {
			redo := key_repeat(.Z) && shift
		} else {
			redo := (key_repeat(.Z) && shift) || key_repeat(.Y)
		}
		if redo {
			res.changed |= restore(e, &e.redo, &e.undo)
		} else if key_repeat(.Z) {
			res.changed |= restore(e, &e.undo, &e.redo)
		}
		if res.changed {
			return
		}
	}

	s := edit_text(e)
	switch {
	case key_repeat(.Left):
		if has_sel && !shift {
			move(e, lo, false)
		} else {
			move(e, line_start(ed, k) if by_line else word_left(s, e.caret) if word else prev_rune(s, e.caret), shift)
		}
	case key_repeat(.Right):
		if has_sel && !shift {
			move(e, hi, false)
		} else {
			move(e, line_end(ed, k) if by_line else word_right(s, e.caret) if word else next_rune(s, e.caret), shift)
		}
	// One line: Up, Down and the page keys are the host's (a palette's list).
	case !opts.multiline && (key_repeat(.Up) || key_repeat(.Down) || key_repeat(.Page_Up) || key_repeat(.Page_Down)):
	case key_repeat(.Up):
		if by_line {
			move(e, 0, shift)
		} else {
			vertical(ed, -1, shift)
		}
	case key_repeat(.Down):
		if by_line {
			move(e, len(s), shift)
		} else {
			vertical(ed, 1, shift)
		}
	case key_repeat(.Page_Up):
		vertical(ed, -max(1, opts.lines if opts.lines > 0 else 6), shift)
	case key_repeat(.Page_Down):
		vertical(ed, max(1, opts.lines if opts.lines > 0 else 6), shift)
	case key_repeat(.Home):
		move(e, 0 if cmd else line_start(ed, k), shift)
	case key_repeat(.End):
		move(e, len(s) if cmd else line_end(ed, k), shift)
	case key_repeat(.Backspace):
		if !has_sel {
			lo = line_start(ed, k) if by_line else word_left(s, e.caret) if word else prev_rune(s, e.caret)
		}
		if lo < hi {
			remember(e, .Delete)
			replace(e, lo, hi, "")
			res.changed = true
		}
	case key_repeat(.Delete):
		if !has_sel {
			hi = line_end(ed, k) if by_line else word_right(s, e.caret) if word else next_rune(s, e.caret)
			lo = e.caret
		}
		if lo < hi {
			remember(e, .Delete)
			replace(e, lo, hi, "")
			res.changed = true
		}
	case key_repeat(.Enter):
		if !opts.multiline || (opts.enter_submits && !shift) {
			res.submitted = true
		} else {
			remember(e, .Other)
			replace(e, lo, hi, "\n")
			res.changed = true
		}
	case key_pressed(.Escape):
		res.cancelled = true
	}

	// Typed text replaces the selection. Typing over a selection, or a space
	// after a word, starts an undo step, so undo takes back a word at a time.
	for r in typed() {
		lo, hi = min(e.caret, e.anchor), max(e.caret, e.anchor)
		if lo != hi || (r == ' ' && e.caret > 0 && e.buf[e.caret - 1] != ' ') {
			e.last_kind = .None
		}
		remember(e, .Type)
		buf, n := utf8.encode_rune(r)
		replace(e, lo, hi, string(buf[:n]))
		res.changed = true
	}
	return
}

@(private = "file")
move :: proc(e: ^Text_Edit, to: int, extend: bool) {
	e.caret = to
	if !extend {
		e.anchor = to
	}
	e.want_x = nil
	e.last_kind = .None
	e.follow = true
}

@(private = "file")
vertical :: proc(ed: ^Editor, delta: int, extend: bool) {
	e := ed.e
	k := line_of(ed.lines[:], e.caret)
	x := e.want_x.? or_else x_of(ed, e.caret)
	nk := clamp(k + delta, 0, len(ed.lines) - 1)
	to: int
	if nk == k {
		// Past the first or last line: to that end, as text views do.
		to = 0 if delta < 0 else len(e.buf)
	} else {
		to = index_at_x(ed, nk, x)
	}
	move(e, to, extend)
	e.want_x = x
}

@(private = "file")
line_start :: proc(ed: ^Editor, k: int) -> int {
	return ed.lines[k].start
}

// Remove [lo, hi) and put s there; the caret lands after it.
@(private = "file")
replace :: proc(e: ^Text_Edit, lo, hi: int, s: string) {
	remove_range(&e.buf, lo, hi)
	inject_at(&e.buf, lo, ..transmute([]u8)s)
	e.caret = lo + len(s)
	e.anchor = e.caret
	e.want_x = nil
	e.follow = true
}

// Line breaks normalized, tabs as spaces (the fonts have no tab glyph),
// and on one line, breaks as spaces. Temp allocated.
@(private = "file")
clean_paste :: proc(s: string, multiline: bool) -> string {
	out, _ := strings.replace_all(s, "\r\n", "\n", context.temp_allocator)
	out, _ = strings.replace_all(out, "\r", "\n", context.temp_allocator)
	out, _ = strings.replace_all(out, "\t", "    ", context.temp_allocator)
	if !multiline {
		out, _ = strings.replace_all(out, "\n", " ", context.temp_allocator)
	}
	return out
}

// --- undo ------------------------------------------------------------------------------

// Before an edit: save the text, unless this edit continues the last one
// (more typing, or more deleting, within a second).
@(private = "file")
remember :: proc(e: ^Text_Edit, kind: Edit_Kind) {
	same := kind != .Other && kind == e.last_kind && s_edit_clock - e.last_time < 1
	e.last_kind = kind
	e.last_time = s_edit_clock
	if same {
		return
	}
	append(&e.undo, snapshot(e))
	if len(e.undo) > UNDO_MAX {
		delete(e.undo[0].text, buf_allocator(e))
		ordered_remove(&e.undo, 0)
	}
	free_snapshots(&e.redo)
}

@(private = "file")
restore :: proc(e: ^Text_Edit, from, to: ^[dynamic]Edit_Snapshot) -> bool {
	if len(from) == 0 {
		return false
	}
	append(to, snapshot(e))
	snap := pop(from)
	clear(&e.buf)
	append(&e.buf, snap.text)
	delete(snap.text, buf_allocator(e))
	e.caret, e.anchor = snap.caret, snap.anchor
	e.want_x = nil
	e.last_kind = .None
	e.follow = true
	return true
}

@(private = "file")
snapshot :: proc(e: ^Text_Edit) -> Edit_Snapshot {
	return {strings.clone(edit_text(e), buf_allocator(e)), e.caret, e.anchor}
}

@(private = "file")
free_snapshots :: proc(list: ^[dynamic]Edit_Snapshot) {
	for s in list {
		delete(s.text, list.allocator)
	}
	clear(list)
}

// Snapshots live with the buffer.
@(private = "file")
buf_allocator :: proc(e: ^Text_Edit) -> runtime.Allocator {
	if e.buf.allocator.procedure == nil {
		e.buf.allocator = context.allocator
	}
	if e.undo.allocator.procedure == nil {
		e.undo.allocator = e.buf.allocator
		e.redo.allocator = e.buf.allocator
	}
	return e.buf.allocator
}

// --- text ------------------------------------------------------------------------------

@(private = "file")
prev_rune :: proc(s: string, i: int) -> int {
	if i <= 0 {
		return 0
	}
	_, w := utf8.decode_last_rune_in_string(s[:i])
	return i - max(w, 1)
}

@(private = "file")
next_rune :: proc(s: string, i: int) -> int {
	if i >= len(s) {
		return len(s)
	}
	_, w := utf8.decode_rune_in_string(s[i:])
	return i + max(w, 1)
}

// Back onto a rune boundary.
@(private = "file")
snap_rune :: proc(s: string, i: int) -> int {
	i := i
	for i > 0 && i < len(s) && !utf8.rune_start(s[i]) {
		i -= 1
	}
	return i
}

// 0 space, 1 word (letters, digits, _), 2 punctuation and the rest.
@(private = "file")
rune_class :: proc(r: rune) -> int {
	if unicode.is_space(r) {
		return 0
	}
	if unicode.is_letter(r) || unicode.is_digit(r) || r == '_' {
		return 1
	}
	return 2
}

// Over spaces, then over the run of one class before them.
@(private = "file")
word_left :: proc(s: string, i: int) -> int {
	i := i
	for i > 0 {
		r, w := utf8.decode_last_rune_in_string(s[:i])
		if rune_class(r) != 0 {
			break
		}
		i -= w
	}
	if i == 0 {
		return 0
	}
	r0, _ := utf8.decode_last_rune_in_string(s[:i])
	c := rune_class(r0)
	for i > 0 {
		r, w := utf8.decode_last_rune_in_string(s[:i])
		if rune_class(r) != c {
			break
		}
		i -= w
	}
	return i
}

@(private = "file")
word_right :: proc(s: string, i: int) -> int {
	i := i
	for i < len(s) {
		r, w := utf8.decode_rune_in_string(s[i:])
		if rune_class(r) != 0 {
			break
		}
		i += w
	}
	if i >= len(s) {
		return len(s)
	}
	r0, _ := utf8.decode_rune_in_string(s[i:])
	c := rune_class(r0)
	for i < len(s) {
		r, w := utf8.decode_rune_in_string(s[i:])
		if rune_class(r) != c {
			break
		}
		i += w
	}
	return i
}

// The run of one class around i (the one after i, or before it at the end).
@(private = "file")
word_at :: proc(s: string, i: int) -> (lo, hi: int) {
	if len(s) == 0 {
		return 0, 0
	}
	at := i if i < len(s) else prev_rune(s, i)
	r0, _ := utf8.decode_rune_in_string(s[at:])
	c := rune_class(r0)
	lo, hi = at, at
	for lo > 0 {
		r, w := utf8.decode_last_rune_in_string(s[:lo])
		if rune_class(r) != c {
			break
		}
		lo -= w
	}
	for hi < len(s) {
		r, w := utf8.decode_rune_in_string(s[hi:])
		if rune_class(r) != c {
			break
		}
		hi += w
	}
	return
}

// The '\n'-delimited line around i, without its '\n'.
@(private = "file")
hard_line_at :: proc(s: string, i: int) -> (lo, hi: int) {
	lo = strings.last_index_byte(s[:i], '\n') + 1
	nl := strings.index_byte(s[i:], '\n')
	hi = len(s) if nl < 0 else i + nl
	return
}

// --- drawing ---------------------------------------------------------------------------

@(private = "file")
draw_line :: proc(ed: ^Editor, k: int, show_caret, has_focus: bool, placeholder: string) {
	st := styles.field
	e := ed.e
	s := edit_text(e)
	l := ed.lines[k]
	lo, hi := min(e.caret, e.anchor), max(e.caret, e.anchor)
	if clay.UI()(clay.ElementDeclaration{
		layout = {
			sizing         = {width = clay.SizingFit({}), height = clay.SizingFixed(ed.line_h)},
			childAlignment = {y = .Center},
		},
	}) {
		switch {
		case len(s) == 0:
			if show_caret {
				caret_run(ed, placeholder, st.placeholder)
			} else {
				run(ed, placeholder, st.placeholder)
			}
		case lo != hi && lo <= l.end && hi > l.start:
			a, b := clamp(lo, l.start, l.end), clamp(hi, l.start, l.end)
			run(ed, s[l.start:a], st.text)
			// A selected line break shows as a space's width of selection.
			newline := l.end < len(s) && s[l.end] == '\n' && lo <= l.end && hi > l.end
			if a < b || newline {
				if clay.UI()(clay.ElementDeclaration{
					layout          = {sizing = {width = clay.SizingFit({}), height = clay.SizingGrow({})}, childAlignment = {y = .Center}},
					backgroundColor = st.selection,
				}) {
					run(ed, s[a:b], st.text)
					if newline {
						if clay.UI()(clay.ElementDeclaration{
							layout = {sizing = {width = clay.SizingFixed(rune_width(' ', ed.font, ed.size)), height = clay.SizingGrow({})}},
						}) {}
					}
				}
			}
			run(ed, s[b:l.end], st.text)
		case show_caret && line_of(ed.lines[:], e.caret) == k:
			run(ed, s[l.start:e.caret], st.text)
			caret_run(ed, s[e.caret:l.end], st.text)
		case:
			run(ed, s[l.start:l.end], st.text)
		}
	}
}

@(private = "file")
run :: proc(ed: ^Editor, s: string, color: Color) {
	if s == "" {
		return
	}
	clay.TextDynamic(s, clay.TextElementConfig{
		fontId    = ed.font,
		fontSize  = ed.size,
		textColor = color,
		wrapMode  = .None,
	})
}

// The text after the caret, with the caret as its left border (drawn over
// the first glyph's side bearing). Never narrower than the caret.
@(private = "file")
caret_run :: proc(ed: ^Editor, s: string, color: Color) {
	w: u16 = 1 if raster_scale() >= 1.5 else 2
	h := min(ed.line_h, math.round(text_draw_size(ed.font, ed.size) * 1.2))
	if clay.UI()(clay.ElementDeclaration{
		layout = {
			sizing         = {width = clay.SizingFit({min = f32(w)}), height = clay.SizingFixed(h)},
			childAlignment = {y = .Center},
		},
		border = {color = styles.field.caret, width = {left = w}},
	}) {
		run(ed, s, color)
	}
}
