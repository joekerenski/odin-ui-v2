package ui

import clay "../deps/clay"

// Design tokens. Mutate `theme` (or swap the whole struct) before building a
// frame to restyle every widget that reads tokens through helpers below.

Color :: clay.Color

Theme :: struct {
	bg:             Color,
	panel:          Color,
	surface:        Color, // tracks, inactive buttons
	surface_hot:    Color, // hover
	border:         Color,
	text:           Color,
	text_dim:       Color,
	text_on_accent: Color,
	accent:         Color,
	accent_hot:     Color,
	warning:        Color,
	danger:         Color,
	success:        Color,

	radius_sm: f32,
	radius_md: f32,

	pad_md: u16,
	gap_md: u16,

	row_h:     f32, // default control height
	slider_h:  f32,
	panel_w:   f32,
	bar_h:     f32, // top bar
	content_w: f32, // max width of centered content (cards)

	font_title: u16,
	font_body:  u16,
	font_small: u16,
	size_title: u16,
	size_body:  u16,
	size_small: u16,
}

// Dark "lab console" defaults — same family as gravsim.
theme := Theme {
	bg             = {10, 12, 20, 255},
	panel          = {18, 22, 34, 255},
	surface        = {38, 44, 62, 255},
	surface_hot    = {30, 36, 52, 255},
	border         = {40, 46, 66, 255},
	text           = {220, 226, 240, 255},
	text_dim       = {130, 140, 165, 255},
	text_on_accent = {10, 14, 26, 255},
	accent         = {110, 170, 255, 255},
	accent_hot     = {140, 190, 255, 255},
	warning        = {255, 190, 90, 255},
	danger         = {255, 110, 110, 255},
	success        = {110, 210, 150, 255},

	radius_sm = 4,
	radius_md = 6,

	pad_md = 12,
	gap_md = 10,

	row_h     = 30,
	slider_h  = 10,
	panel_w   = 300,
	bar_h     = 44,
	content_w = 760,

	font_title = 0,
	font_body  = 1,
	font_small = 2,
	size_title = 28,
	size_body  = 16,
	size_small = 14,
}

// --- resolved per-widget styles ----------------------------------------------
//
// Widgets read `styles.<widget>.<field>` for chrome. `reset_styles()` re-derives
// every field from the current `theme` tokens.

Button_Style :: struct {
	bg:             Color,
	bg_hover:       Color,
	text:           Color,
	accent_bg:      Color,
	accent_hover:   Color,
	text_on_accent: Color,
	radius:         f32,
	height:         f32,
}

Toggle_Style :: struct {
	bg:      Color,
	text:    Color,
	on_bg:   Color,
	on_text: Color,
	radius:  f32,
	height:  f32,
}

Slider_Style :: struct {
	track:      Color,
	label:      Color,
	value:      Color,
	knob:       Color,
	knob_inner: Color,
	height:     f32,
	knob_r:     f32,
}

Panel_Style :: struct {
	bg:      Color,
	padding: u16,
	gap:     u16,
}

Dropdown_Style :: struct {
	bg:            Color,
	bg_hover:      Color,
	text:          Color,
	selected_bg:   Color,
	selected_text: Color,
	menu_bg:       Color,
	menu_border:   Color,
	radius:        f32,
	height:        f32,
}

Icon_Style :: struct {
	bg:       Color,
	bg_hover: Color,
	glyph:    Color,
	radius:   f32,
	size:     f32,
}

Top_Bar_Style :: struct {
	bg:      Color,
	border:  Color,
	height:  f32,
	padding: u16,
	gap:     u16,
}

Tab_Bar_Style :: struct {
	text:            Color,
	text_hover:      Color,
	text_on:         Color,
	underline:       Color,
	underline_hover: Color,
	underline_h:     f32,
	pad_x:           u16,
	gap:             u16,
}

Card_Style :: struct {
	bg:      Color,
	border:  Color,
	title:   Color,
	radius:  f32,
	padding: u16,
	gap:     u16,
	max_w:   f32,
}

Scroll_Style :: struct {
	thumb:     Color,
	thumb_hot: Color,
	width:     f32,
	inset:     f32, // gap between thumb and the container edge
	min_thumb: f32,
	padding:   u16,
	gap:       u16,
}

Widget_Styles :: struct {
	button:   Button_Style,
	toggle:   Toggle_Style,
	slider:   Slider_Style,
	panel:    Panel_Style,
	dropdown: Dropdown_Style,
	icon:     Icon_Style,
	top_bar:  Top_Bar_Style,
	tab_bar:  Tab_Bar_Style,
	card:     Card_Style,
	scroll:   Scroll_Style,
}

styles: Widget_Styles

styles_from_theme :: proc(t: Theme) -> Widget_Styles {
	return Widget_Styles{
		button = {
			bg             = t.surface,
			bg_hover       = t.surface_hot,
			text           = t.text,
			accent_bg      = t.accent,
			accent_hover   = t.accent_hot,
			text_on_accent = t.text_on_accent,
			radius         = t.radius_sm,
			height         = t.row_h,
		},
		toggle = {
			bg      = t.surface,
			text    = t.text,
			on_bg   = t.accent,
			on_text = t.text_on_accent,
			radius  = t.radius_sm,
			height  = t.row_h,
		},
		slider = {
			track      = t.surface,
			label      = t.text,
			value      = t.accent,
			knob       = t.accent,
			knob_inner = t.bg,
			height     = t.slider_h,
			knob_r     = 6,
		},
		panel = {
			bg      = t.panel,
			padding = u16(t.pad_md + 2),
			gap     = t.gap_md,
		},
		dropdown = {
			bg            = t.surface,
			bg_hover      = t.surface_hot,
			text          = t.text,
			selected_bg   = t.accent,
			selected_text = t.text_on_accent,
			menu_bg       = t.panel,
			menu_border   = t.border,
			radius        = t.radius_sm,
			height        = t.row_h,
		},
		icon = {
			bg       = t.surface,
			bg_hover = t.surface_hot,
			glyph    = t.text,
			radius   = t.radius_sm,
			size     = 26,
		},
		top_bar = {
			bg      = t.panel,
			border  = t.border,
			height  = t.bar_h,
			padding = u16(t.pad_md + 2),
			gap     = u16(t.gap_md * 2),
		},
		tab_bar = {
			text            = t.text_dim,
			text_hover      = t.text,
			text_on         = t.text,
			underline       = t.accent,
			underline_hover = t.border,
			underline_h     = 2,
			pad_x           = t.pad_md,
			gap             = 2,
		},
		card = {
			bg      = t.panel,
			border  = t.border,
			title   = t.text,
			radius  = t.radius_md,
			padding = u16(t.pad_md + 4),
			gap     = t.gap_md,
			max_w   = t.content_w,
		},
		scroll = {
			thumb     = t.surface,
			thumb_hot = t.text_dim,
			width     = 6,
			inset     = 3,
			min_thumb = 24,
			padding   = u16(t.pad_md * 2),
			gap       = u16(t.gap_md * 2),
		},
	}
}

// Re-derive `styles` from the current `theme` tokens.
reset_styles :: proc() {
	styles = styles_from_theme(theme)
}
