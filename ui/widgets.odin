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
root_begin :: proc(id: string = "Root", transparent: bool = false) -> bool {
	clay.OpenElementWithId(clay.ID(id))
	bg := theme.bg
	if transparent {
		bg = {0, 0, 0, 0}
	}
	return clay.ConfigureOpenElement(clay.ElementDeclaration{
		layout = {
			sizing          = {width = clay.SizingGrow({}), height = clay.SizingGrow({})},
			layoutDirection = .LeftToRight,
		},
		backgroundColor = bg,
	})
}

Panel_Opts :: struct {
	// Mask children horizontally to the panel bounds — lets an animated width
	// "fold" the panel while clipping the reflowing content (scissor).
	clip_x: bool,
}

// Side panel column.
panel_begin :: proc(id: string = "Panel", width: f32 = 0, opts: Panel_Opts = {}) -> bool {
	w := width if width > 0 else theme.panel_w
	clay.OpenElementWithId(clay.ID(id))
	return clay.ConfigureOpenElement(clay.ElementDeclaration{
		layout = {
			sizing          = {width = clay.SizingFixed(w), height = clay.SizingGrow({})},
			layoutDirection = .TopToBottom,
			padding         = clay.PaddingAll(styles.panel.padding),
			childGap        = styles.panel.gap,
		},
		backgroundColor = styles.panel.bg,
		clip            = {horizontal = opts.clip_x},
	})
}

// Growable content area (e.g. canvas). Host draws into this via region/clip.
canvas_begin :: proc(id: string = "Canvas", bg: Color = {8, 10, 16, 255}) -> bool {
	clay.OpenElementWithId(clay.ID(id))
	return clay.ConfigureOpenElement(clay.ElementDeclaration{
		layout = {sizing = {width = clay.SizingGrow({}), height = clay.SizingGrow({})}},
		backgroundColor = bg,
	})
}

// Closes a container opened by root_begin, panel_begin, or canvas_begin.
element_end :: proc() {
	clay.CloseElement()
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

	// Knob from previous-frame track box. Floats unclipped (clipTo=.None) — it
	// is bigger than the track and hangs past the ends at min/max by design.
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
		backgroundColor = {12, 16, 28, 210},
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
		dim("F3 hide")
	}
}

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
