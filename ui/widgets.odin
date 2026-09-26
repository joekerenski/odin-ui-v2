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
	text(title_text, theme.font_body, theme.size_body, st.title)
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
		data.scrollPosition.y = -t * max_scroll
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
	col := st.thumb
	if hovered(thumb_id) || dragging(thumb_id) {
		col = st.thumb_hot
	}
	if clay.UI(clay.ID(thumb_id))(clay.ElementDeclaration{
		layout          = {sizing = {width = clay.SizingFixed(st.width), height = clay.SizingFixed(thumb_h)}},
		backgroundColor = col,
		cornerRadius    = clay.CornerRadiusAll(st.width * 0.5),
		floating = {
			attachTo   = .ElementWithId,
			parentId   = clay.ID(id).id,
			attachment = {element = .RightTop, parent = .RightTop},
			offset     = {-st.inset, st.inset + t * (track - thumb_h)},
			zIndex     = 5,
		},
	}) {}
}

// --- button -----------------------------------------------------------------

Button_Opts :: struct {
	accent:   bool,
	height:   f32,
	disabled: bool,
}

button :: proc(id, label: string, opts: Button_Opts = {}) -> bool {
	hot := hovered(id) && !opts.disabled
	bg := styles.button.bg
	tc := styles.button.text
	if opts.disabled {
		bg = styles.button.bg
		tc = theme.text_dim
	} else if opts.accent {
		bg = styles.button.accent_bg
		tc = styles.button.text_on_accent
	}
	if hot {
		if opts.accent {
			bg = styles.button.accent_hover
		} else {
			bg = styles.button.bg_hover
		}
	}
	h := opts.height if opts.height > 0 else styles.button.height
	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {
			sizing         = {width = clay.SizingGrow({}), height = clay.SizingFixed(h)},
			childAlignment = {x = .Center, y = .Center},
			padding        = clay.Padding{theme.pad_md, theme.pad_md, 0, 0},
		},
		backgroundColor = bg,
		cornerRadius    = clay.CornerRadiusAll(styles.button.radius),
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
	sz := size if size > 0 else styles.icon.size
	bg := styles.icon.bg
	if hovered(id) {
		bg = styles.icon.bg_hover
	}
	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {
			sizing         = {width = clay.SizingFixed(sz), height = clay.SizingFixed(sz)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = bg,
		cornerRadius    = clay.CornerRadiusAll(styles.icon.radius),
	}) {}
	// Chevron from previous-frame box (one-frame lag on first show is fine).
	if box, ok := element_box(id); ok {
		cx := box.x + box.width * 0.5
		cy := box.y + box.height * 0.5
		col := styles.icon.glyph
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

toggle :: proc(id, label: string, on: bool) -> bool {
	bg := styles.toggle.bg
	tc := styles.toggle.text
	if on {
		bg = styles.toggle.on_bg
		tc = styles.toggle.on_text
	}
	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {
			sizing         = {width = clay.SizingGrow({}), height = clay.SizingFixed(styles.toggle.height)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = bg,
		cornerRadius    = clay.CornerRadiusAll(styles.toggle.radius),
	}) {
		text(label, theme.font_small, theme.size_small, tc)
	}
	if clicked(id) {
		return !on
	}
	return on
}

// --- slider -----------------------------------------------------------------

// Single-call slider: builds chrome, resolves drag, draws knob via Custom circle.
// Returns the (possibly new) value.
slider :: proc(id, label: string, value: f32, lo, hi: f32, value_fmt: string = "%.2f") -> f32 {
	v := drag_value_x(id, value, lo, hi)

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
			text(label, theme.font_small, theme.size_small, styles.slider.label)
		}
		text(value_text, theme.font_small, theme.size_small, styles.slider.value)
	}
	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingFixed(styles.slider.height)}},
		backgroundColor = styles.slider.track,
		cornerRadius    = clay.CornerRadiusAll(styles.slider.height * 0.5),
	}) {}

	// Knob from previous-frame track box. It is bigger than the track and hangs
	// past the ends at min/max by design; see custom_circle_at for clipping.
	if box, ok := element_box(id); ok {
		t := math.clamp((v - lo) / (hi - lo), 0, 1)
		x := box.x + t * box.width
		cy := box.y + box.height * 0.5
		r := styles.slider.knob_r
		custom_circle_at(fmt.tprintf("%s_knob", id), id, x, cy, r, styles.slider.knob)
		custom_circle_at(fmt.tprintf("%s_knob_in", id), id, x, cy, r * 0.5, styles.slider.knob_inner)
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
	result := selected

	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {
			sizing         = {width = clay.SizingGrow({}), height = clay.SizingFixed(styles.dropdown.height + 2)},
			childAlignment = {x = .Left, y = .Center},
			padding        = clay.Padding{theme.pad_md, theme.pad_md, 0, 0},
		},
		backgroundColor = styles.dropdown.bg,
		cornerRadius    = clay.CornerRadiusAll(styles.dropdown.radius),
	}) {
		shown := label
		if selected >= 0 && selected < len(options) {
			shown = options[selected]
		}
		text(shown, theme.font_small, theme.size_small, styles.dropdown.text)
	}

	// Chevron (previous-frame trigger box).
	if box, ok := element_box(id); ok {
		x := box.x + box.width - 16
		cy := box.y + box.height * 0.5
		custom_triangle_at(
			fmt.tprintf("%s_chev", id),
			id,
			{x, cy - 3.5},
			{x + 7, cy - 3.5},
			{x + 3.5, cy + 3.5},
			theme.text_dim,
		)
	}

	menu_id := fmt.tprintf("%s_menu", id)

	if state.open {
		if clay.UI(clay.ID(menu_id))(clay.ElementDeclaration{
			layout = {
				sizing          = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
				layoutDirection = .TopToBottom,
				childGap        = 2,
			},
			backgroundColor = styles.dropdown.menu_bg,
			border = {
				color = styles.dropdown.menu_border,
				width = clay.BorderWidth{1, 1, 1, 1, 0},
			},
			cornerRadius = clay.CornerRadiusAll(theme.radius_md),
			overlayColor = {255, 255, 255, 255},
			transition   = fade_transition(0.15),
			floating = {
				attachTo           = .ElementWithId,
				parentId           = clay.ID(id).id,
				attachment         = {element = .LeftTop, parent = .LeftBottom},
				offset             = {0, 6},
				zIndex             = 1000,
				pointerCaptureMode = .Capture,
			},
		}) {
			for opt, i in options {
				item_id := fmt.tprintf("%s_item_%d", id, i)
				hov := hovered(item_id)
				bg := styles.dropdown.bg
				tc := styles.dropdown.text
				if i == selected {
					bg = styles.dropdown.selected_bg
					tc = styles.dropdown.selected_text
				} else if hov {
					bg = styles.dropdown.bg_hover
				}
				if clay.UI(clay.ID(item_id))(clay.ElementDeclaration{
					layout = {
						sizing         = {width = clay.SizingGrow({}), height = clay.SizingFixed(styles.dropdown.height)},
						childAlignment = {x = .Left, y = .Center},
						padding        = clay.Padding{theme.pad_md, theme.pad_md, 0, 0},
					},
					backgroundColor = bg,
					cornerRadius    = clay.CornerRadiusAll(styles.dropdown.radius),
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
// underline sits on the bar's bottom border. Returns the selected index.
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
			hot := !on && hovered(item)
			tc := st.text
			line := Color{}
			if on {
				tc = st.text_on
				line = st.underline
			} else if hot {
				tc = st.text_hover
				line = st.underline_hover
			}
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
	}
	return result
}

// Segmented control: equal-width pills. Returns the selected index.
tabs :: proc(id: string, labels: []string, selected: int) -> int {
	result := selected
	if clay.UI(clay.ID(id))(clay.ElementDeclaration{
		layout = {
			sizing          = {width = clay.SizingGrow({}), height = clay.SizingFit({})},
			layoutDirection = .LeftToRight,
			childGap        = 4,
		},
	}) {
		for label, i in labels {
			item := fmt.tprintf("%s_%d", id, i)
			on := i == selected
			bg := styles.toggle.bg
			tc := styles.toggle.text
			if on {
				bg = styles.toggle.on_bg
				tc = styles.toggle.on_text
			} else if hovered(item) {
				bg = styles.button.bg_hover
			}
			if clay.UI(clay.ID(item))(clay.ElementDeclaration{
				layout = {
					sizing         = {width = clay.SizingGrow({}), height = clay.SizingFixed(styles.toggle.height)},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = bg,
				cornerRadius    = clay.CornerRadiusAll(styles.toggle.radius),
			}) {
				text(label, theme.font_small, theme.size_small, tc)
			}
			if clicked(item) {
				result = i
			}
		}
	}
	return result
}
