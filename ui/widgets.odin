package ui

import clay "../deps/clay"
import "core:fmt"
import "core:math"

// Layout primitives + interactive controls.
//
// Components are single-call: they build Clay chrome *and* resolve interaction
// against previous-frame geometry, returning the new value/click in one shot.
// Decorations (knobs, chevrons) are Clay Custom/floating elements so every
// backend renders them through the normal clay command stream.

// --- layout chrome ----------------------------------------------------------

spacer :: proc(id: string) {
	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}},
	}) {}
}

divider :: proc(id: string) {
	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(1)}},
		backgroundColor = theme.border,
	}) {}
}

// Full-window root with background fill. Use transparent=true when the host
// draws content underneath the UI (see host_raylib / host_sokol).
root_begin :: proc(id: string = "Root", transparent: bool = false, direction: clay.LayoutDirection = .LeftToRight) -> bool {
	clay.OpenElementWithId(clay.ID(id))
	bg := theme.bg
	if transparent {
		bg = {0, 0, 0, 0}
	}
	return clay.ConfigureOpenElement(clay.ElementDeclaration{
		layout = {
			sizing          = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			layoutDirection = direction,
		},
		backgroundColor = bg,
	})
}

Panel_Opts :: struct {
	// Mask children horizontally to the panel bounds — lets an animated width
	// "fold" the panel while clipping the reflowing content (scissor).
	clip_x: bool,
}

// Side panel column. Scrolls when its content is taller than the window;
// close it with panel_end(id), which draws the scrollbar.
panel_begin :: proc(id: string = "Panel", width: f32 = 0, opts: Panel_Opts = {}) -> bool {
	w := width if width > 0 else theme.panel_w
	scroll_track(id)
	scrollbar_drag(id)
	clay.OpenElementWithId(clay.ID(id))
	return clay.ConfigureOpenElement(clay.ElementDeclaration{
		layout = {
			sizing          = {width = clay.SizingFixed(w), height = clay.SizingGrow({})},
			layoutDirection = .TopToBottom,
			padding         = clay.PaddingAll(styles.panel.padding),
			childGap        = styles.panel.gap,
		},
		backgroundColor = styles.panel.bg,
		clip            = {horizontal = opts.clip_x, vertical = true, childOffset = clay.GetScrollOffset()},
	})
}

panel_end :: proc(id: string = "Panel") {
	clay.CloseElement()
	scrollbar(id)
}

// Growable content area (e.g. canvas). Host draws into this via region/clip.
// Fills with theme.canvas unless `bg` is given ({} for none).
canvas_begin :: proc(id: string = "Canvas", bg: Maybe(Color) = nil) -> bool {
	clay.OpenElementWithId(clay.ID(id))
	return clay.ConfigureOpenElement(clay.ElementDeclaration{
		layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}},
		backgroundColor = bg.? or_else theme.canvas,
	})
}

// Full-width bar with a bottom border, children in a centered row. Put it
// first in a root opened with direction = .TopToBottom.
top_bar_begin :: proc(id: string = "TopBar") -> bool {
	st := styles.top_bar
	clay.OpenElementWithId(clay.ID(id))
	return clay.ConfigureOpenElement(clay.ElementDeclaration{
		layout = {
			sizing          = {width = clay.SizingGrow({}), height = clay.SizingFixed(st.height)},
			layoutDirection = .LeftToRight,
			padding         = clay.Padding{st.padding, st.padding, 0, 0},
			childGap        = st.gap,
			childAlignment  = {y = .Center},
		},
		backgroundColor = st.bg,
		border          = {color = st.border, width = clay.BorderWidth{bottom = 1}},
	})
}

Box_Opts :: struct {
	gap:     u16,
	padding: u16,
	grow_h:  bool,  // fill the parent's height too (a body row under a top bar)
	height:  f32,   // fixed height; 0 fits the children
	bg:      Color, // alpha 0 = no fill
	radius:  f32,
}

// Horizontal container, full width. Children share the width: controls that
// grow (button, toggle, slider) split it evenly.
row_begin :: proc(id: string, opts: Box_Opts = {}) -> bool {
	return box_begin(id, .LeftToRight, opts)
}

// Vertical container, full width, children stacked.
column_begin :: proc(id: string, opts: Box_Opts = {}) -> bool {
	return box_begin(id, .TopToBottom, opts)
}

@(private)
box_begin :: proc(id: string, direction: clay.LayoutDirection, opts: Box_Opts) -> bool {
	h := clay.SizingFit({})
	if opts.grow_h {
		h = clay.SizingGrow({})
	} else if opts.height > 0 {
		h = clay.SizingFixed(opts.height)
	}
	clay.OpenElementWithId(clay.ID(id))
	return clay.ConfigureOpenElement(clay.ElementDeclaration{
		layout = {
			sizing          = {width = clay.SizingGrow({}), height = h},
			layoutDirection = direction,
			padding         = clay.PaddingAll(opts.padding),
			childGap        = opts.gap,
			childAlignment  = {y = .Center} if direction == .LeftToRight else {},
		},
		backgroundColor = opts.bg,
		cornerRadius    = clay.CornerRadiusAll(opts.radius),
	})
}

// Bordered surface with a title, children stacked. Width grows up to
// `styles.card.max_w`; a parent that centers children centers the card.
card_begin :: proc(id, title_text: string, subtitle: string = "") -> bool {
	st := styles.card
	clay.OpenElementWithId(clay.ID(id))
	open := clay.ConfigureOpenElement(clay.ElementDeclaration{
		layout = {
			sizing          = {width = clay.SizingGrow({max = st.max_w}), height = clay.SizingFit({})},
			layoutDirection = .TopToBottom,
			padding         = clay.PaddingAll(st.padding),
			childGap        = st.gap,
		},
		backgroundColor = st.bg,
		border          = {color = st.border, width = clay.BorderWidth{1, 1, 1, 1, 0}},
		cornerRadius    = clay.CornerRadiusAll(st.radius),
	})
	text(title_text, theme.font_heading, theme.size_heading, st.title)
	if subtitle != "" {
		dim(subtitle)
	}
	return open
}

// Fixed-size filled rectangle. width 0 grows to fill the row. An outline
// (alpha > 0) draws a 1px border, so a color that matches its background
// still shows.
swatch :: proc(id: string, color: Color, width: f32 = 0, height: f32 = 0, radius: f32 = -1, outline: Color = {}) {
	w := clay.SizingGrow({}) if width <= 0 else clay.SizingFixed(width)
	h := height if height > 0 else theme.row_h
	r := radius if radius >= 0 else theme.radius_sm
	bw: u16 = 1 if outline.a > 0 else 0
	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout          = {sizing = {width = w, height = clay.SizingFixed(h)}},
		backgroundColor = color,
		border          = {color = outline, width = clay.BorderWidth{bw, bw, bw, bw, 0}},
		cornerRadius    = clay.CornerRadiusAll(r),
	}) {}
}

// Closes a container opened by root_begin, canvas_begin, top_bar_begin,
// row_begin, column_begin, or card_begin. (panel_begin and scroll_begin have
// their own _end, which also draws the scrollbar.)
element_end :: proc() {
	clay.CloseElement()
}

// --- scroll container -------------------------------------------------------

// Vertical scroll area that fills its parent, children stacked and centered.
// The wheel scrolls whatever container is under the pointer (Clay does that in
// begin_layout). The thumb is a floating child; dragging it maps the pointer
// across the track. Close with scroll_end(id).
//
// The drag is resolved here, before the container opens, so the new offset
// lands in this frame's layout.
scroll_begin :: proc(id: string) -> bool {
	st := styles.scroll
	scroll_track(id)
	scrollbar_drag(id)
	clay.OpenElementWithId(clay.ID(id))
	return clay.ConfigureOpenElement(clay.ElementDeclaration{
		layout = {
			sizing          = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			layoutDirection = .TopToBottom,
			padding         = clay.PaddingAll(st.padding),
			childGap        = st.gap,
			childAlignment  = {x = .Center},
		},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	})
}

scroll_end :: proc(id: string) {
	clay.CloseElement()
	scrollbar(id)
}

// Where on the thumb the drag grabbed it, so the thumb doesn't jump.
@(private)
_scroll_grab: f32

// Resolve a drag on scroll container `id`'s thumb. Call before the container
// opens, so the new offset lands in this frame's layout.
@(private)
scrollbar_drag :: proc(id: string) {
	st := styles.scroll
	thumb_id := fmt.tprintf("%s_thumb", id)
	data := clay.GetScrollContainerData(clay.ID(id))
	if !drag_update(thumb_id) || !data.found {
		return
	}
	thumb, t_ok := element_box(thumb_id)
	view, v_ok := element_box(id)
	travel := data.scrollContainerDimensions.height - 2 * st.inset - thumb.height
	max_scroll := data.contentDimensions.height - data.scrollContainerDimensions.height
	if t_ok && v_ok && travel > 0 && max_scroll > 0 {
		if mouse_pressed(.Left) {
			_scroll_grab = input.mouse_y - thumb.y
		}
		t := math.clamp((input.mouse_y - _scroll_grab - view.y - st.inset) / travel, 0, 1)
		scroll_jump(id, -t * max_scroll)
	}
}

// The thumb for scroll container `id`, as a floating child, when its content
// overflows. Call after the container closes.
@(private)
scrollbar :: proc(id: string) {
	st := styles.scroll
	data := clay.GetScrollContainerData(clay.ID(id))
	view := data.scrollContainerDimensions.height
	content := data.contentDimensions.height
	if !data.found || content <= view + 0.5 {
		return
	}
	track := view - 2 * st.inset
	thumb_h := math.clamp(track * view / content, st.min_thumb, track)
	t := math.clamp(-data.scrollPosition.y / (content - view), 0, 1)

	thumb_id := fmt.tprintf("%s_thumb", id)
	hk := anim(thumb_id, 1 if hovered(thumb_id) || dragging(thumb_id) else 0, theme.motion.hover)
	w := st.width * (1 + 0.4 * hk)
	if clay.UI(clay.ID(thumb_id))(clay.ElementDeclaration{
		layout          = {sizing = {width = clay.SizingFixed(w), height = clay.SizingFixed(thumb_h)}},
		backgroundColor = mix(st.thumb, st.thumb_hot, hk),
		cornerRadius    = clay.CornerRadiusAll(w * 0.5),
		floating = {
			attachTo   = .ElementWithId,
			parentId   = clay.ID(id).id,
			attachment = {element = .RightTop, parent = .RightTop},
			offset     = {-st.inset, st.inset + t * (track - thumb_h)},
			zIndex     = 5,
		},
	}) {}
}

// --- feedback -----------------------------------------------------------------

// Show a control in a state without the pointer on it (specimens, docs).
Force :: enum u8 {
	None,
	Hover,
	Press,
}

// Whether the pointer is over a control, and held down on it.
press_state :: proc(id: string, force: Force = .None, disabled := false) -> (hot, held: bool) {
	if disabled {
		return
	}
	hot = s_interactions_enabled && hovered(id)
	held = hot && mouse_down(.Left)
	switch force {
	case .None:
	case .Hover:
		hot = true
	case .Press:
		hot, held = true, true
	}
	return
}

// The eased color of a control: `rest` toward `over` while hovered, then
// darker by the press depth while held, in either mode. Uses anim channels 1
// and 2 of `id`.
feedback :: proc(id: string, rest, over: Color, hot, held: bool) -> Color {
	h := anim(id, 1 if hot else 0, theme.motion.hover, channel = 1)
	p := anim(id, 1 if held else 0, theme.motion.hover * 0.5, channel = 2)
	c := mix(rest, over, h)
	return mix(c, Color{0, 0, 0, c.a}, theme.motion.press * p)
}

@(private)
clear_of :: proc(c: Color) -> Color {
	return {c.r, c.g, c.b, 0}
}

// --- button -----------------------------------------------------------------

Button_Opts :: struct {
	accent:   bool,
	height:   f32,
	disabled: bool,
	force:    Force,
}

button :: proc(id, label: string, opts: Button_Opts = {}) -> bool {
	st := styles.button
	hot, held := press_state(id, opts.force, opts.disabled)
	rest, over, tc := st.bg, st.bg_hover, st.text
	if opts.accent {
		rest, over, tc = st.accent_bg, st.accent_hover, st.text_on_accent
	}
	if opts.disabled {
		rest, over, tc = st.bg, st.bg, theme.text_dim
	}
	h := opts.height if opts.height > 0 else st.height
	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {
			sizing         = {width = clay.SizingGrow({}), height = clay.SizingFixed(h)},
			childAlignment = {x = .Center, y = .Center},
			padding        = clay.Padding{theme.pad_md, theme.pad_md, 0, 0},
		},
		backgroundColor = feedback(id, rest, over, hot, held),
		cornerRadius    = clay.CornerRadiusAll(st.radius),
	}) {
		text(label, theme.font_small, theme.size_small, tc)
	}
	if opts.disabled {
		return false
	}
	return clicked(id)
}

// --- icon button ------------------------------------------------------------

Icon :: enum {
	ChevronLeft,
	ChevronRight,
}

// Small square button. Returns true on click. Chevron is drawn as a Clay Custom
// triangle (any backend renders it).
icon_button :: proc(id: string, icon: Icon = .ChevronLeft, size: f32 = 0) -> bool {
	st := styles.icon
	sz := size if size > 0 else st.size
	hot, held := press_state(id)
	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {
			sizing         = {width = clay.SizingFixed(sz), height = clay.SizingFixed(sz)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = feedback(id, st.bg, st.bg_hover, hot, held),
		cornerRadius    = clay.CornerRadiusAll(st.radius),
	}) {}
	// Chevron from previous-frame box (one-frame lag on first show is fine).
	if box, ok := element_box(id); ok {
		cx := box.x + box.width * 0.5
		cy := box.y + box.height * 0.5
		col := st.glyph
		#partial switch icon {
		case .ChevronLeft:
			custom_triangle_at(fmt.tprintf("%s_ico", id), id, {cx - 4.5, cy}, {cx + 3.5, cy - 5.5}, {cx + 3.5, cy + 5.5}, col)
		case .ChevronRight:
			custom_triangle_at(fmt.tprintf("%s_ico", id), id, {cx + 4.5, cy}, {cx - 3.5, cy - 5.5}, {cx - 3.5, cy + 5.5}, col)
		}
	}
	return clicked(id)
}

// --- toggle -----------------------------------------------------------------

// A pill that fills with the accent when on.
toggle :: proc(id, label: string, on: bool) -> bool {
	st := styles.toggle
	hot, held := press_state(id)
	k := anim(id, 1 if on else 0, theme.motion.change)
	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {
			sizing         = {width = clay.SizingGrow({}), height = clay.SizingFixed(st.height)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = feedback(id, mix(st.bg, st.on_bg, k), mix(st.bg_hover, st.on_hover, k), hot, held),
		cornerRadius    = clay.CornerRadiusAll(st.radius),
	}) {
		text(label, theme.font_small, theme.size_small, mix(st.text, st.on_text, k))
	}
	if clicked(id) {
		return !on
	}
	return on
}

// A label and an on/off switch; the whole row toggles. The knob slides with
// the change duration and the bounce.
toggle_switch :: proc(id, label: string, on: bool) -> bool {
	st := styles.toggle
	track_id := fmt.tprintf("%s_track", id)
	track_h := math.round(st.height * 0.66)
	track_w := math.round(track_h * 1.75)
	hot, held := press_state(id)
	k := anim(id, 1 if on else 0, theme.motion.change, theme.motion.bounce)
	kc := math.clamp(k, 0, 1)
	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {
			sizing          = {width = clay.SizingGrow({}), height = clay.SizingFixed(st.height)},
			layoutDirection = .LeftToRight,
			childAlignment  = {y = .Center},
			childGap        = theme.gap_md,
		},
	}) {
		if clay.UI(clay.ID(id, 1))(clay.ElementDeclaration{
			layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}},
		}) {
			text(label, theme.font_small, theme.size_small, st.text)
		}
		if clay.UI(clay.ID(track_id))(clay.ElementDeclaration{
			layout          = {sizing = {width = clay.SizingFixed(track_w), height = clay.SizingFixed(track_h)}},
			backgroundColor = feedback(id, mix(st.bg, st.on_bg, kc), mix(st.bg_hover, st.on_hover, kc), hot, held),
			cornerRadius    = clay.CornerRadiusAll(track_h * 0.5),
		}) {}
	}
	if box, ok := element_box(track_id); ok {
		pad := max(2, math.round(track_h * 0.12))
		r := track_h * 0.5 - pad
		x := box.x + pad + r + k * (box.width - 2 * pad - 2 * r)
		custom_circle_at(fmt.tprintf("%s_knob", id), track_id, x, box.y + box.height * 0.5, r, mix(st.knob, st.on_text, kc))
	}
	if clicked(id) {
		return !on
	}
	return on
}

// --- slider -----------------------------------------------------------------

// Single-call slider: a label row, then the track, filled up to the knob.
// The hit area is taller than the track. The knob eases to a click and
// follows a drag closely, and grows while hovered. Returns the (possibly new)
// value.
slider :: proc(id, label: string, value: f32, lo, hi: f32, value_fmt: string = "%.2f") -> f32 {
	st := styles.slider
	v := drag_value_x(id, value, lo, hi)
	drag := dragging(id)
	hot := drag || (s_interactions_enabled && hovered(id))

	value_text := fmt.tprintf(value_fmt, v)
	if clay.UI(clay.ID(id, 1))(clay.ElementDeclaration{
		layout = {
			sizing          = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childAlignment  = {x = .Left, y = .Center},
		},
	}) {
		if clay.UI(clay.ID(id, 2))(clay.ElementDeclaration{
			layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}},
		}) {
			text(label, theme.font_small, theme.size_small, st.label)
		}
		text(value_text, theme.font_small, theme.size_small, st.value)
	}

	t := math.clamp((v - lo) / (hi - lo), 0, 1) if hi != lo else 0
	tk := anim(id, t, 0.05 if drag else theme.motion.change)
	hk := anim(id, 1 if hot else 0, theme.motion.hover, channel = 1)
	hit_h := max(st.knob_r * 2 + 4, st.height)
	fill_w: f32
	if box, ok := element_box(id); ok {
		fill_w = math.clamp(tk, 0, 1) * box.width
	}
	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {
			sizing         = {width = clay.SizingGrow({}), height = clay.SizingFixed(hit_h)},
			childAlignment = {y = .Center},
		},
	}) {
		if clay.UI(clay.ID(id, 3))(clay.ElementDeclaration{
			layout          = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(st.height)}},
			backgroundColor = st.track,
			cornerRadius    = clay.CornerRadiusAll(st.height * 0.5),
		}) {
			if clay.UI(clay.ID(id, 4))(clay.ElementDeclaration{
				layout          = {sizing = {width = clay.SizingFixed(fill_w), height = clay.SizingGrow({})}},
				backgroundColor = st.fill if fill_w >= st.height else clear_of(st.fill),
				cornerRadius    = clay.CornerRadiusAll(st.height * 0.5),
			}) {}
		}
	}

	// Knob from previous-frame track box. It hangs past the ends at min/max
	// by design; see custom_circle_at for clipping.
	if box, ok := element_box(id); ok {
		x := box.x + tk * box.width
		cy := box.y + box.height * 0.5
		r := st.knob_r * (1 + 0.25 * hk)
		custom_circle_at(fmt.tprintf("%s_knob", id), id, x, cy, r, st.knob)
		custom_circle_at(fmt.tprintf("%s_knob_in", id), id, x, cy, r * 0.5, st.knob_inner)
	}
	return v
}

// --- dropdown / picker ------------------------------------------------------

Dropdown :: struct {
	open: bool,
}

// Single-call dropdown. `state` is host-owned open/closed; returns selection index.
dropdown :: proc(
	state: ^Dropdown,
	id: string,
	label: string,
	options: []string,
	selected: int,
) -> int {
	st := styles.dropdown
	result := selected
	hot, held := press_state(id)

	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {
			sizing         = {width = clay.SizingGrow({}), height = clay.SizingFixed(st.height + 2)},
			childAlignment = {x = .Left, y = .Center},
			padding        = clay.Padding{theme.pad_md, theme.pad_md + 16, 0, 0},
		},
		backgroundColor = feedback(id, st.bg, st.bg_hover, hot || state.open, held),
		cornerRadius    = clay.CornerRadiusAll(st.radius),
	}) {
		shown := label
		if selected >= 0 && selected < len(options) {
			shown = options[selected]
		}
		text(shown, theme.font_small, theme.size_small, st.text)
	}

	// Chevron (previous-frame trigger box); turns over as the menu opens.
	if box, ok := element_box(id); ok {
		spin := anim(id, 1 if state.open else 0, theme.motion.change, theme.motion.bounce, channel = 3) * math.PI
		c := [2]f32{box.x + box.width - 12.5, box.y + box.height * 0.5}
		turn :: proc(c: [2]f32, p: [2]f32, a: f32) -> [2]f32 {
			s, co := math.sin(a), math.cos(a)
			return {c.x + p.x * co - p.y * s, c.y + p.x * s + p.y * co}
		}
		custom_triangle_at(
			fmt.tprintf("%s_chev", id),
			id,
			turn(c, {-3.5, -1.75}, spin),
			turn(c, {3.5, -1.75}, spin),
			turn(c, {0, 2.75}, spin),
			theme.text_dim,
		)
	}

	menu_id := fmt.tprintf("%s_menu", id)

	if state.open {
		// Drops into place from a little higher as it fades in.
		e := anim(menu_id, 1, theme.motion.enter, from = 0)
		if clay.UI(clay.ID(menu_id))(clay.ElementDeclaration{
			layout = {
				sizing          = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
				layoutDirection = .TopToBottom,
				childGap        = 2,
				padding         = clay.PaddingAll(3),
			},
			backgroundColor = st.menu_bg,
			border = {
				color = st.menu_border,
				width = clay.BorderWidth{1, 1, 1, 1, 0},
			},
			cornerRadius = clay.CornerRadiusAll(theme.radius_md),
			overlayColor = {255, 255, 255, 255},
			transition   = fade_transition(max(theme.motion.enter * 0.6, 0.001)),
			floating = {
				attachTo           = .ElementWithId,
				parentId           = clay.ID(id).id,
				attachment         = {element = .LeftTop, parent = .LeftBottom},
				offset             = {0, 6 - 8 * (1 - e)},
				zIndex             = 1000,
				pointerCaptureMode = .Capture,
			},
		}) {
			for opt, i in options {
				item_id := fmt.tprintf("%s_item_%d", id, i)
				i_hot, i_held := press_state(item_id)
				bg := feedback(item_id, clear_of(st.bg_hover), st.bg_hover, i_hot, i_held)
				tc := st.text
				if i == selected {
					bg = st.selected_bg
					tc = st.selected_text
				}
				if clay.UI(clay.ID(item_id))(clay.ElementDeclaration{
					layout = {
						sizing         = {width = clay.SizingGrow({}), height = clay.SizingFixed(st.height)},
						childAlignment = {x = .Left, y = .Center},
						padding        = clay.Padding{theme.pad_md - 3, theme.pad_md - 3, 0, 0},
					},
					backgroundColor = bg,
					cornerRadius    = clay.CornerRadiusAll(max(0, st.radius - 1)),
				}) {
					text(opt, theme.font_small, theme.size_small, tc)
				}
			}
		}
	}

	// Interaction (previous-frame geometry for items/trigger).
	if clicked(id) {
		state.open = !state.open
		return result
	}
	// The menu floats unclipped, so it would ride over a top bar once its
	// trigger scrolls under it. Close it on scroll instead.
	if state.open && (input.wheel_x != 0 || input.wheel_y != 0) {
		state.open = false
	}
	if state.open {
		for _, i in options {
			item_id := fmt.tprintf("%s_item_%d", id, i)
			if clicked(item_id) {
				state.open = false
				return i
			}
		}
		if mouse_pressed(.Left) {
			btn, b_ok := element_box(id)
			menu, m_ok := element_box(menu_id)
			in_btn := b_ok && mouse_in_box(btn)
			in_menu := m_ok && mouse_in_box(menu)
			if !in_btn && !in_menu {
				state.open = false
			}
		}
	}
	return result
}

// --- color picker -----------------------------------------------------------

@(private)
Picker :: struct {
	out:     Color, // what it returned last; a different color coming in resets h, s, v
	h, s, v: f32,
	seen:    u64,
}

@(private)
s_pickers: map[u32]Picker

// Hue, saturation and brightness over gradient tracks, with a swatch and the
// hex value. Returns the color, and whether a track moved; until one does,
// the color comes back exactly as given. Alpha is kept. Hue is remembered
// through grays and black, where the color alone loses it.
color_picker :: proc(id: string, c: Color) -> (out: Color, changed: bool) {
	key := clay.ID(id).id
	p := s_pickers[key]
	if p.out != c || p.seen == 0 {
		h, s, v := rgb_to_hsv(c)
		if s > 0 && v > 0 || p.seen == 0 {
			p.h = h
		}
		p.s, p.v = s, v
	}
	p.seen = s_frame
	shown := c if p.out != c else hsv_to_rgb(p.h, p.s, p.v, c.a)

	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {
			sizing          = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .TopToBottom,
			childGap        = theme.gap_md,
		},
	}) {
		if clay.UI(clay.ID(id, 1))(clay.ElementDeclaration{
			layout = {
				sizing          = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
				layoutDirection = .LeftToRight,
				childGap        = theme.gap_md,
				childAlignment  = {y = .Center},
			},
		}) {
			swatch(fmt.tprintf("%s_sw", id), shown, 40, 40, outline = theme.border)
			if clay.UI(clay.ID(id, 2))(clay.ElementDeclaration{
				layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFit({})}, layoutDirection = .TopToBottom, childGap = 2},
			}) {
				body(hex(shown))
				dim(fmt.tprintf("H %.0f°   S %.0f%%   B %.0f%%", p.h, p.s * 100, p.v * 100))
			}
		}
		hues: [GRADIENT_STOPS]Color
		for i in 0 ..< GRADIENT_STOPS {
			hues[i] = hsv_to_rgb(f32(i) * 60, 1, 1)
		}
		// Sliders hand back their input untouched when not dragged.
		ht := p.h / 360
		if nt := gradient_slider(fmt.tprintf("%s_h", id), ht, hues[:]); nt != ht {
			p.h, changed = nt * 360, true
		}
		if ns := gradient_slider(fmt.tprintf("%s_s", id), p.s, {hsv_to_rgb(p.h, 0, p.v), hsv_to_rgb(p.h, 1, p.v)}); ns != p.s {
			p.s, changed = ns, true
		}
		if nv := gradient_slider(fmt.tprintf("%s_v", id), p.v, {{0, 0, 0, 255}, hsv_to_rgb(p.h, p.s, 1)}); nv != p.v {
			p.v, changed = nv, true
		}
	}
	out = hsv_to_rgb(p.h, p.s, p.v, c.a) if changed else c
	p.out = out
	s_pickers[key] = p
	return
}

// A 0..1 slider over a gradient track, the knob showing the color under it.
gradient_slider :: proc(id: string, t: f32, stops: []Color) -> f32 {
	h := max(14, styles.slider.height * 2)
	nt := drag_value_x(id, t, 0, 1, h * 0.5) // the knob travels inset by its radius
	d := Custom_Data{kind = .Gradient}
	for c, i in stops[:min(len(stops), GRADIENT_STOPS)] {
		d.stops[i] = c
		d.count += 1
	}
	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(h)}},
		custom = {customData = custom_push(d)},
	}) {}
	if box, ok := element_box(id); ok && len(stops) > 0 {
		r := box.height * 0.5
		x := box.x + r + nt * (box.width - 2 * r)
		cy := box.y + r
		f := nt * f32(len(stops) - 1)
		i := min(int(f), len(stops) - 1)
		under := stops[i] if i + 1 >= len(stops) else mix(stops[i], stops[i + 1], f - f32(i))
		custom_circle_at(fmt.tprintf("%s_ring", id), id, x, cy, r + 2, theme.text)
		custom_circle_at(fmt.tprintf("%s_dot", id), id, x, cy, r - 1, under)
	}
	return nt
}

@(private)
picker_tick :: proc() {
	stale := make([dynamic]u32, context.temp_allocator)
	for key, p in s_pickers {
		if p.seen + 1 < s_frame {
			append(&stale, key)
		}
	}
	for key in stale {
		delete_key(&s_pickers, key)
	}
}

@(private)
debug_strip_on := true

debug_strip :: proc() {
	if key_pressed(.F3) {
		debug_strip_on = !debug_strip_on
	}
	if !debug_strip_on {
		return
	}
	st := stats()
	if clay.UI(clay.ID("UiDebug"))(clay.ElementDeclaration{
		layout = {
			sizing          = {width = clay.SizingFit({}), height = clay.SizingFit({})},
			layoutDirection = .TopToBottom,
			padding         = clay.PaddingAll(8),
			childGap        = 1,
		},
		backgroundColor = theme.scrim,
		cornerRadius    = clay.CornerRadiusAll(theme.radius_sm),
		floating = {
			attachTo           = .Root,
			zIndex             = 3000,
			pointerCaptureMode = .Passthrough,
			attachment         = {element = .LeftBottom, parent = .LeftBottom},
			offset             = {10, -10},
		},
	}) {
		dim(fmt.tprintf("%d fps   busy %.2f / %.2f ms", st.fps, st.busy_ms, st.frame_ms))
		dim(fmt.tprintf("clay %d KB   %d cmds   custom %d/%d", st.clay_kb, st.cmds, st.custom, st.custom_max))
		dim(fmt.tprintf("zoom %d%%   F3 hide", int(math.round(st.zoom * 100))))
	}
}

// Navigation tabs for a top bar: text labels, the selected one underlined in
// the accent color. Items fit their label and fill the bar's height, so the
// underline sits on the bar's bottom border; it slides to a new selection.
// Returns the selected index.
tab_bar :: proc(id: string, labels: []string, selected: int) -> int {
	st := styles.tab_bar
	result := selected
	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {
			sizing          = {width = clay.SizingFit({}), height = clay.SizingGrow({})},
			layoutDirection = .LeftToRight,
			childGap        = st.gap,
		},
	}) {
		for label, i in labels {
			item := fmt.tprintf("%s_%d", id, i)
			on := i == selected
			hk := anim(item, 1 if !on && hovered(item) else 0, theme.motion.hover)
			ok := anim(item, 1 if on else 0, theme.motion.change, channel = 1)
			tc := mix(mix(st.text, st.text_hover, hk), st.text_on, ok)
			line := st.underline_hover
			line.a *= hk
			if clay.UI(clay.ID(item))(clay.ElementDeclaration{
				layout = {
					sizing          = {width = clay.SizingFit({}), height = clay.SizingGrow({})},
					layoutDirection = .TopToBottom,
				},
			}) {
				if clay.UI(clay.ID(item, 1))(clay.ElementDeclaration{
					layout = {
						sizing         = {width = clay.SizingFit({}), height = clay.SizingGrow({})},
						padding        = clay.Padding{st.pad_x, st.pad_x, 0, 0},
						childAlignment = {x = .Center, y = .Center},
					},
				}) {
					text(label, theme.font_body, theme.size_body, tc)
				}
				if clay.UI(clay.ID(item, 2))(clay.ElementDeclaration{
					layout          = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(st.underline_h)}},
					backgroundColor = line,
				}) {}
			}
			if clicked(item) {
				result = i
			}
		}
		// The accent underline, from the previous frame's boxes.
		bar, bar_ok := element_box(id)
		sel, sel_ok := element_box(fmt.tprintf("%s_%d", id, selected))
		if bar_ok && sel_ok && selected >= 0 {
			x := anim(id, sel.x - bar.x, theme.motion.change, theme.motion.bounce)
			w := anim(id, sel.width, theme.motion.change, theme.motion.bounce, channel = 1)
			if clay.UI(clay.ID(id, 1))(clay.ElementDeclaration{
				layout          = {sizing = {width = clay.SizingFixed(max(0, w)), height = clay.SizingFixed(st.underline_h)}},
				backgroundColor = st.underline,
				floating = {
					attachTo           = .Parent,
					offset             = {x, bar.height - st.underline_h},
					zIndex             = 1,
					pointerCaptureMode = .Passthrough,
				},
			}) {}
		}
	}
	return result
}

// Segmented control: a track split into equal segments, the selected one on
// an accent pill that slides between them. Returns the selected index; -1
// selects none.
tabs :: proc(id: string, labels: []string, selected: int) -> int {
	st := styles.toggle
	result := selected
	PAD :: 3
	pos := anim(id, f32(selected), theme.motion.change, theme.motion.bounce)
	inner_r := max(0, st.radius - PAD * 0.5)
	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {
			sizing          = {width = clay.SizingGrow({}), height = clay.SizingFixed(st.height)},
			layoutDirection = .LeftToRight,
			padding         = clay.PaddingAll(PAD),
		},
		backgroundColor = st.bg,
		cornerRadius    = clay.CornerRadiusAll(st.radius),
	}) {
		// Floating, so it can sit between segments; labels float above it.
		if box, ok := element_box(id); ok && len(labels) > 0 && selected >= 0 {
			w := (box.width - 2 * PAD) / f32(len(labels))
			if clay.UI(clay.ID(id, 1))(clay.ElementDeclaration{
				layout          = {sizing = {width = clay.SizingFixed(w), height = clay.SizingFixed(box.height - 2 * PAD)}},
				backgroundColor = st.on_bg,
				cornerRadius    = clay.CornerRadiusAll(inner_r),
				floating = {
					attachTo           = .Parent,
					// Bounce overshoots pos; the track doesn't clip its children.
					offset             = {PAD + math.clamp(pos, 0, f32(len(labels) - 1)) * w, PAD},
					zIndex             = 1,
					pointerCaptureMode = .Passthrough,
					clipTo             = .AttachedParent,
				},
			}) {}
		}
		for label, i in labels {
			item := fmt.tprintf("%s_%d", id, i)
			on_k := math.clamp(1 - math.abs(pos - f32(i)), 0, 1) if selected >= 0 else 0
			hot, held := press_state(item)
			if i == selected {
				hot, held = false, false
			}
			if clay.UI(clay.ID(item))(clay.ElementDeclaration{
				layout          = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}},
				backgroundColor = feedback(item, clear_of(st.bg_hover), st.bg_hover, hot, held),
				cornerRadius    = clay.CornerRadiusAll(inner_r),
			}) {
				if clay.UI(clay.ID(item, 1))(clay.ElementDeclaration{
					layout = {sizing = {width = clay.SizingFit({}), height = clay.SizingFit({})}},
					floating = {
						attachTo           = .Parent,
						attachment         = {element = .CenterCenter, parent = .CenterCenter},
						zIndex             = 2,
						pointerCaptureMode = .Passthrough,
						clipTo             = .AttachedParent,
					},
				}) {
					text(label, theme.font_small, theme.size_small, mix(st.text, st.on_text, on_k))
				}
			}
			if clicked(item) {
				result = i
			}
		}
	}
	return result
}
