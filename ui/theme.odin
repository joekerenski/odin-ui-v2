package ui

import clay "../deps/clay"
import "core:math"

// Design tokens. `theme` is a Palette (colors), Metrics (shape and spacing),
// Typography (text sizes and the font slot of each role), and Motion. Fields
// read through `using`, so `theme.bg`, `theme.pad_md` and `theme.size_body`
// all work; motion is `theme.motion.hover`. Widgets read `styles`, which
// reset_styles() derives from `theme`.
//
// Change colors with set_palette (optionally cross-faded), not by poking
// fields, so `styles` follows. A palette usually comes from a Theme_Base, a
// few colors any theme source can provide (a preset, Omarchy's colors.toml,
// a system appearance), with the rest mixed from them by palette_from_base.
// A whole look, colors for both modes included, is a Design (design.odin).
//
// Struct tags drive the design file and the Design tab's editor:
// `range:"lo,hi"` bounds a token, `label` names it, `unit:"ms"` shows seconds
// as milliseconds, and `design:"-"` keeps a field out of design files.

Color :: clay.Color

Palette :: struct {
	bg:             Color,
	panel:          Color, // side panel, top bar, cards
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
	canvas:         Color, // host drawing areas (the graph)
	scrim:          Color, // translucent floating chrome (the debug strip)
}

Metrics :: struct {
	radius_sm: f32 `range:"0,16" label:"Radius, controls"`,
	radius_md: f32 `range:"0,24" label:"Radius, cards and menus"`,
	pad_md:    u16 `range:"4,24" label:"Padding"`,
	gap_md:    u16 `range:"2,20" label:"Gap"`,
	row_h:     f32 `range:"22,48" label:"Control height"`, // default control height
	slider_h:  f32 `range:"2,16" label:"Slider track"`,
	panel_w:   f32 `range:"220,420" label:"Panel width"`,
	bar_h:     f32 `range:"32,64" label:"Top bar height"`,
	content_w: f32 `range:"520,1100" label:"Content width"`, // max width of centered content (cards)
}

// A font per role, and its size. The font ids are slots filled by
// apply_design (or load_font), not design tokens.
Type_Role :: enum u8 {
	Title,
	Heading,
	Body,
	Small,
}

Typography :: struct {
	font_title:   u16 `design:"-"`,
	font_heading: u16 `design:"-"`,
	font_body:    u16 `design:"-"`,
	font_small:   u16 `design:"-"`,
	size_title:   u16 `range:"16,48" label:"Title"`,
	size_heading: u16 `range:"12,28" label:"Heading"`,
	size_body:    u16 `range:"11,22" label:"Body"`,
	size_small:   u16 `range:"9,18" label:"Small"`,
}

// How the UI moves. Durations are seconds, about the time a change takes to
// settle (see `anim`).
Motion :: struct {
	hover:  f32 `range:"0,0.4" unit:"ms" label:"Hover"`,          // hover and press
	change: f32 `range:"0,0.6" unit:"ms" label:"Change"`,         // toggles, selection, sliding indicators
	enter:  f32 `range:"0,0.6" unit:"ms" label:"Enter"`,          // menus appearing, theme cross-fades
	scroll: f32 `range:"0,0.4" unit:"ms" label:"Scroll"`,         // wheel smoothing, 0 = off
	bounce: f32 `range:"0,0.6" label:"Bounce"`,                   // overshoot on things that move
	press:  f32 `range:"0,0.5" label:"Press depth"`,              // how far a held control darkens
}

Theme :: struct {
	using palette:    Palette,
	using metrics:    Metrics,
	using typography: Typography,
	motion:           Motion,
}

// Dark "lab console" defaults, same family as gravsim. What `theme` holds
// before a design is applied, and the fallback status colors.
PALETTE_DARK :: Palette {
	bg             = {10, 12, 20, 255},
	panel          = {18, 22, 34, 255},
	surface        = {38, 44, 62, 255},
	surface_hot    = {52, 58, 76, 255},
	border         = {40, 46, 66, 255},
	text           = {220, 226, 240, 255},
	text_dim       = {130, 140, 165, 255},
	text_on_accent = {10, 14, 26, 255},
	accent         = {110, 170, 255, 255},
	accent_hot     = {140, 190, 255, 255},
	warning        = {255, 190, 90, 255},
	danger         = {255, 110, 110, 255},
	success        = {110, 210, 150, 255},
	canvas         = {8, 10, 16, 255},
	scrim          = {12, 16, 28, 210},
}

// The same look as a base, for designs: palette_from_base(BASE_DARK).
BASE_DARK :: Theme_Base {
	mode       = .Dark,
	background = {10, 12, 20, 255},
	foreground = {220, 226, 240, 255},
	accent     = {110, 170, 255, 255},
	surface    = {38, 44, 62, 255},
	border     = {40, 46, 66, 255},
	warning    = {255, 190, 90, 255},
	danger     = {255, 110, 110, 255},
	success    = {110, 210, 150, 255},
}

// Light counterpart, derived: palette_from_base(BASE_LIGHT).
BASE_LIGHT :: Theme_Base {
	mode       = .Light,
	background = {244, 245, 249, 255},
	foreground = {28, 32, 46, 255},
	accent     = {38, 104, 220, 255},
	warning    = {196, 120, 20, 255},
	danger     = {206, 60, 60, 255},
	success    = {40, 150, 90, 255},
}

METRICS_DEFAULT :: Metrics {
	radius_sm = 4,
	radius_md = 6,

	pad_md = 12,
	gap_md = 8,

	row_h     = 30,
	slider_h  = 6,
	panel_w   = 280,
	bar_h     = 44,
	content_w = 760,
}

TYPOGRAPHY_DEFAULT :: Typography {
	font_title   = u16(Type_Role.Title),
	font_heading = u16(Type_Role.Heading),
	font_body    = u16(Type_Role.Body),
	font_small   = u16(Type_Role.Small),
	size_title   = 28,
	size_heading = 17,
	size_body    = 16,
	size_small   = 14,
}

MOTION_DEFAULT :: Motion {
	hover  = 0.12,
	change = 0.22,
	enter  = 0.25,
	scroll = 0.14,
	bounce = 0.15,
	press  = 0.25,
}

theme := Theme {
	palette    = PALETTE_DARK,
	metrics    = METRICS_DEFAULT,
	typography = TYPOGRAPHY_DEFAULT,
	motion     = MOTION_DEFAULT,
}

// --- theme bases ----------------------------------------------------------------

Theme_Mode :: enum u8 {
	Dark,
	Light,
}

// The few colors a theme source has to provide. Alpha 0 means "derive it".
Theme_Base :: struct {
	mode:           Theme_Mode `design:"-"`,
	background:     Color,
	foreground:     Color,
	accent:         Color,
	surface:        Color, // controls; default: background mixed 14% toward foreground
	border:         Color, // default: 16% toward foreground
	text_on_accent: Color, // default: whichever reads best; macOS sets its white
	warning:        Color,
	danger:         Color,
	success:        Color,
}

// Fill a whole palette from a base. Shades mix background toward foreground,
// so they work in either mode: in a dark theme they lighten, in a light one
// they darken. A few floors keep low-contrast themes readable (checked
// against all of Omarchy's themes): dim text stays at 3.5:1 or better, text
// on the accent at 4.5:1 where black or white can reach it, and a given
// surface is only used when it stands out from the background.
palette_from_base :: proc(b: Theme_Base) -> Palette {
	bg, fg := opaque(b.background), opaque(b.foreground)
	dark := b.mode == .Dark
	p: Palette
	p.bg = bg
	p.panel = mix(bg, fg, 0.05)
	p.surface = mix(bg, fg, 0.14)
	if b.surface.a > 0 && contrast(b.surface, bg) >= min(1.35, contrast(p.surface, bg)) {
		p.surface = opaque(b.surface)
	}
	// Hover lifts a control toward the text: lighter in a dark theme,
	// darker in a light one.
	p.surface_hot = mix(p.surface, fg, 0.08)
	p.border = opaque(b.border) if b.border.a > 0 else mix(bg, fg, 0.16)
	p.text = fg
	dim_t := f32(0.42)
	for dim_t > 0.1 && contrast(mix(fg, bg, dim_t), bg) < 3.5 {
		dim_t -= 0.04
	}
	p.text_dim = mix(fg, bg, dim_t)
	p.accent = opaque(b.accent)
	p.accent_hot = mix(p.accent, {255, 255, 255, 255}, 0.2) if dark else mix(p.accent, {0, 0, 0, 255}, 0.15)
	// Whichever of background and foreground reads better on the accent;
	// near-black or near-white when neither reaches 4.5:1 and one of them does
	// better.
	p.text_on_accent = bg if contrast(bg, p.accent) >= contrast(fg, p.accent) else fg
	if contrast(p.text_on_accent, p.accent) < 4.5 {
		for c in ([2]Color{{16, 16, 20, 255}, {250, 250, 250, 255}}) {
			if contrast(c, p.accent) > contrast(p.text_on_accent, p.accent) {
				p.text_on_accent = c
			}
		}
	}
	if b.text_on_accent.a > 0 {
		p.text_on_accent = opaque(b.text_on_accent)
	}
	p.warning = b.warning if b.warning.a > 0 else PALETTE_DARK.warning
	p.danger = b.danger if b.danger.a > 0 else PALETTE_DARK.danger
	p.success = b.success if b.success.a > 0 else PALETTE_DARK.success
	p.canvas = mix(bg, {0, 0, 0, 255}, 0.22) if dark else mix(bg, {255, 255, 255, 255}, 0.5)
	p.scrim = p.panel
	p.scrim.a = 215
	return p
}

// Swap the palette; metrics stay. `fade` seconds cross-fades from the current
// colors (0 = at once). `styles` follows every frame of the fade.
set_palette :: proc(p: Palette, fade: f32 = 0) {
	if fade <= 0 {
		s_fade = {}
		theme.palette = p
		reset_styles()
		return
	}
	s_fade = {from = theme.palette, to = p, t = 0, duration = fade, active = true}
}

// Swap palette and metrics at once, no fade.
set_theme :: proc(t: Theme) {
	s_fade = {}
	theme = t
	reset_styles()
}

@(private)
s_fade: struct {
	from, to: Palette,
	t:        f32,
	duration: f32,
	active:   bool,
}

// Palette's field count: it holds only Colors, so it also casts to an array.
PALETTE_LEN :: size_of(Palette) / size_of(Color)
#assert(size_of(Palette) % size_of(Color) == 0, "Palette must hold only Colors")

// Advance a running palette fade. Called by `frame`.
@(private)
theme_tick :: proc(dt: f32) {
	if !s_fade.active {
		return
	}
	s_fade.t = min(s_fade.t + dt / s_fade.duration, 1)
	k := ease_in_out_cubic(s_fade.t)
	from := transmute([PALETTE_LEN]Color)s_fade.from
	to := transmute([PALETTE_LEN]Color)s_fade.to
	out: [PALETTE_LEN]Color
	for i in 0 ..< PALETTE_LEN {
		out[i] = from[i] + (to[i] - from[i]) * k
	}
	theme.palette = transmute(Palette)out
	reset_styles()
	if s_fade.t >= 1 {
		s_fade.active = false
	}
}

// --- color math -------------------------------------------------------------------

// a + (b - a) * t per channel, alpha included.
mix :: proc(a, b: Color, t: f32) -> Color {
	return a + (b - a) * t
}

@(private)
opaque :: proc(c: Color) -> Color {
	return {c.r, c.g, c.b, 255}
}

// WCAG relative luminance, 0..1.
luminance :: proc(c: Color) -> f32 {
	lin :: proc(v: f32) -> f32 {
		v := v / 255
		return v / 12.92 if v <= 0.04045 else math.pow((v + 0.055) / 1.055, 2.4)
	}
	return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}

// WCAG contrast ratio, 1..21.
contrast :: proc(a, b: Color) -> f32 {
	la, lb := luminance(a), luminance(b)
	return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

// Hue in degrees 0..360, saturation and value 0..1. Alpha is left out.
rgb_to_hsv :: proc(c: Color) -> (h, s, v: f32) {
	r, g, b := c.r / 255, c.g / 255, c.b / 255
	hi := max(r, g, b)
	lo := min(r, g, b)
	d := hi - lo
	v = hi
	s = d / hi if hi > 0 else 0
	if d <= 0 {
		return
	}
	if hi == r {
		h = 60 * math.mod((g - b) / d, 6)
	} else if hi == g {
		h = 60 * ((b - r) / d + 2)
	} else {
		h = 60 * ((r - g) / d + 4)
	}
	if h < 0 {
		h += 360
	}
	return
}

hsv_to_rgb :: proc(h, s, v: f32, alpha: f32 = 255) -> Color {
	h := math.mod(h, 360)
	if h < 0 {
		h += 360
	}
	c := v * s
	x := c * (1 - math.abs(math.mod(h / 60, 2) - 1))
	m := v - c
	r, g, b: f32
	switch {
	case h < 60:
		r, g, b = c, x, 0
	case h < 120:
		r, g, b = x, c, 0
	case h < 180:
		r, g, b = 0, c, x
	case h < 240:
		r, g, b = 0, x, c
	case h < 300:
		r, g, b = x, 0, c
	case:
		r, g, b = c, 0, x
	}
	return {(r + m) * 255, (g + m) * 255, (b + m) * 255, alpha}
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
	bg:       Color,
	bg_hover: Color,
	text:     Color,
	on_bg:    Color,
	on_hover: Color,
	on_text:  Color,
	knob:     Color, // the switch's knob
	radius:   f32,
	height:   f32,
}

Slider_Style :: struct {
	track:      Color,
	fill:       Color, // the track up to the knob
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
			bg       = t.surface,
			bg_hover = t.surface_hot,
			text     = t.text,
			on_bg    = t.accent,
			on_hover = t.accent_hot,
			on_text  = t.text_on_accent,
			knob     = t.text,
			radius   = t.radius_sm,
			height   = t.row_h,
		},
		slider = {
			track      = t.surface,
			fill       = t.accent,
			label      = t.text,
			value      = t.accent,
			knob       = t.accent,
			knob_inner = t.bg,
			height     = t.slider_h,
			knob_r     = max(6, t.slider_h),
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
