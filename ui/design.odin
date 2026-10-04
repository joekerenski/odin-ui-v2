package ui

import "core:fmt"
import "core:math"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"

// A design is the whole look and feel in one file another project can load:
// a font and size per text role, shape and spacing (Metrics), motion, and
// colors for dark and light.
//
//   ui.register_font("Inter-Medium", #load("fonts/Inter-Medium.ttf"))
//   d, ok := ui.load_design("designs/console.toml")
//   defer ui.design_destroy(&d)
//   ui.apply_design(d, .Dark)
//
// Or embedded: ui.parse_design(string(#load("look.toml"))). Keys a file
// leaves out keep the built-in design's value; unknown keys are reported and
// skipped.
//
// A font is a name given to register_font, or a path to a .ttf/.otf relative
// to the design file. An empty or missing one falls back to the first font
// registered.
//
// Colors: each mode is a Theme_Base (a few colors; palette_from_base mixes
// the rest) plus any palette fields set by hand. Only the base is required,
// so a new mode is three colors: background, foreground, accent.

Color_Set :: struct {
	base:       Theme_Base,
	overrides:  Palette,
	overridden: bit_set[0 ..< PALETTE_LEN], // indexes into Palette's fields
}

Design :: struct {
	name:       string,
	dir:        string, // where relative font paths start; "" is the working directory
	fonts:      [Type_Role]string,
	typography: Typography,
	metrics:    Metrics,
	motion:     Motion,
	dark:       Color_Set,
	light:      Color_Set,
}

ROLE_NAMES := [Type_Role]string {
	.Title   = "title",
	.Heading = "heading",
	.Body    = "body",
	.Small   = "small",
	.Mono    = "mono",
}

// The built-in design. Its strings are allocated; free with design_destroy.
default_design :: proc(allocator := context.allocator) -> Design {
	return {
		name       = strings.clone("Console", allocator),
		typography = TYPOGRAPHY_DEFAULT,
		metrics    = METRICS_DEFAULT,
		motion     = MOTION_DEFAULT,
		dark       = {base = BASE_DARK},
		light      = {base = BASE_LIGHT},
	}
}

design_clone :: proc(d: Design, allocator := context.allocator) -> Design {
	out := d
	out.name = strings.clone(d.name, allocator)
	out.dir = strings.clone(d.dir, allocator)
	for &f in out.fonts {
		f = strings.clone(f, allocator)
	}
	return out
}

design_destroy :: proc(d: ^Design, allocator := context.allocator) {
	delete(d.name, allocator)
	delete(d.dir, allocator)
	for f in d.fonts {
		delete(f, allocator)
	}
	d^ = {}
}

// Replace a design's string field, freeing the old one.
design_set_string :: proc(field: ^string, value: string, allocator := context.allocator) {
	old := field^
	field^ = strings.clone(value, allocator)
	delete(old, allocator)
}

color_set :: proc(d: ^Design, mode: Theme_Mode) -> ^Color_Set {
	return &d.dark if mode == .Dark else &d.light
}

// The full palette a color set describes.
palette_of :: proc(s: Color_Set) -> Palette {
	p := transmute([PALETTE_LEN]Color)palette_from_base(s.base)
	over := transmute([PALETTE_LEN]Color)s.overrides
	for i in s.overridden {
		p[i] = over[i]
	}
	return transmute(Palette)p
}

// Palette field names, in order: the keys of a [dark.palette] section.
palette_field_names :: proc() -> []string {
	return reflect.struct_field_names(Palette)
}

// --- applying --------------------------------------------------------------------

@(private)
s_design_sets: [Theme_Mode]Color_Set = {
	.Dark  = {base = BASE_DARK},
	.Light = {base = BASE_LIGHT},
}

@(private)
Applied_Font :: struct {
	face: string, // owned
	dir:  string, // owned
	size: u16,
}

@(private)
s_applied_fonts: [Type_Role]Applied_Font

// Make `d` the look: metrics, typography (fonts are rasterized when a role's
// font or size changed), motion, and the color sets design_palette reads.
// With a mode, the palette switches too (cross-faded over `fade` seconds);
// nil keeps the current colors, for an app that takes them from the system.
// Call after init. `d` is copied; it can be freed after.
apply_design :: proc(d: Design, mode: Maybe(Theme_Mode) = .Dark, fade: f32 = 0) {
	ids := theme.typography
	theme.metrics = d.metrics
	theme.motion = d.motion
	theme.typography = d.typography
	theme.font_title, theme.font_heading = ids.font_title, ids.font_heading
	theme.font_body, theme.font_small = ids.font_body, ids.font_small
	theme.font_mono = ids.font_mono
	s_design_sets = {
		.Dark  = d.dark,
		.Light = d.light,
	}
	for role in Type_Role {
		apply_font(role, d.fonts[role], d.dir, role_size(theme.typography, role))
	}
	if m, ok := mode.?; ok {
		set_palette(design_palette(m), fade)
	} else {
		reset_styles()
	}
}

// The palette of the applied design's dark or light colors.
design_palette :: proc(mode: Theme_Mode) -> Palette {
	return palette_of(s_design_sets[mode])
}

role_size :: proc(t: Typography, role: Type_Role) -> u16 {
	switch role {
	case .Title:
		return t.size_title
	case .Heading:
		return t.size_heading
	case .Body:
		return t.size_body
	case .Small:
		return t.size_small
	case .Mono:
		return t.size_mono
	}
	return t.size_body
}

role_font :: proc(t: Typography, role: Type_Role) -> u16 {
	switch role {
	case .Title:
		return t.font_title
	case .Heading:
		return t.font_heading
	case .Body:
		return t.font_body
	case .Small:
		return t.font_small
	case .Mono:
		return t.font_mono
	}
	return t.font_body
}

@(private)
apply_font :: proc(role: Type_Role, face, dir: string, size: u16) {
	a := &s_applied_fonts[role]
	id := role_font(theme.typography, role)
	if a.size == size && a.face == face && a.dir == dir && int(id) < len(fonts) && fonts[id].font.glyphCount > 0 {
		return
	}
	delete(a.face)
	delete(a.dir)
	a^ = {face = strings.clone(face), dir = strings.clone(dir), size = size}

	data, path, found := font_source(face, dir)
	if !found && face != "" {
		fmt.eprintfln("ui: font %q not registered or found, using the default", face)
	}
	if path != "" {
		cpath := strings.clone_to_cstring(path, context.temp_allocator)
		load_font(id, size, cpath)
		if fonts[id].font.glyphCount > 0 {
			return
		}
		data = default_font_data()
	}
	if len(data) > 0 {
		load_font_data(id, size, data)
	}
}

// Where a font comes from: registered bytes, or a file path.
@(private)
font_source :: proc(face, dir: string) -> (data: []u8, path: string, found: bool) {
	if face != "" {
		for f in s_registry {
			if f.name == face {
				return f.data, "", true
			}
		}
		p := face
		if !os.is_absolute_path(face) && dir != "" {
			p, _ = os.join_path({dir, face}, context.temp_allocator)
		}
		if os.is_file(p) {
			return nil, p, true
		}
	}
	return default_font_data(), "", false
}

// --- font registry ---------------------------------------------------------------

@(private)
Registered_Font :: struct {
	name: string, // owned
	data: []u8,   // borrowed
}

@(private)
s_registry: [dynamic]Registered_Font

// Name font bytes (usually #load'ed) so designs can use them by name. The
// first one registered is the fallback. `data` must outlive the UI.
register_font :: proc(name: string, data: []u8) {
	for &f in s_registry {
		if f.name == name {
			f.data = data
			return
		}
	}
	append(&s_registry, Registered_Font{name = strings.clone(name), data = data})
}

registered_fonts :: proc(allocator := context.temp_allocator) -> []string {
	out := make([]string, len(s_registry), allocator)
	for f, i in s_registry {
		out[i] = f.name
	}
	return out
}

@(private)
default_font_data :: proc() -> []u8 {
	if len(s_registry) == 0 {
		return nil
	}
	return s_registry[0].data
}

@(private)
design_teardown :: proc() {
	for f in s_registry {
		delete(f.name)
	}
	delete(s_registry)
	s_registry = nil
	for &a in s_applied_fonts {
		delete(a.face)
		delete(a.dir)
		a = {}
	}
}

// --- tokens ------------------------------------------------------------------------
//
// A design's numbers, found by reflection, so a token added to Metrics,
// Typography or Motion shows up in design files and editors on its own.

Token :: struct {
	key:   string, // field name, the key in a design file
	label: string,
	unit:  string, // "ms": seconds shown as milliseconds
	lo:    f32,
	hi:    f32,
	ptr:   rawptr,
	whole: bool, // an integer token
}

// The tokens of a Metrics, Typography, or Motion.
tokens :: proc(ptr: ^$T, allocator := context.temp_allocator) -> []Token {
	out := make([dynamic]Token, allocator)
	for f in reflect.struct_fields_zipped(T) {
		if skip_field(f.tag) {
			continue
		}
		t := Token {
			key   = f.name,
			label = f.name,
			ptr   = rawptr(uintptr(ptr) + f.offset),
			whole = f.type.id == u16,
		}
		if f.type.id != f32 && f.type.id != u16 {
			continue
		}
		if l, ok := reflect.struct_tag_lookup(f.tag, "label"); ok {
			t.label = l
		}
		if u, ok := reflect.struct_tag_lookup(f.tag, "unit"); ok {
			t.unit = u
		}
		if r, ok := reflect.struct_tag_lookup(f.tag, "range"); ok {
			if comma := strings.index_byte(r, ','); comma > 0 {
				t.lo, _ = strconv.parse_f32(r[:comma])
				t.hi, _ = strconv.parse_f32(r[comma + 1:])
			}
		}
		append(&out, t)
	}
	return out[:]
}

token_get :: proc(t: Token) -> f32 {
	return f32((^u16)(t.ptr)^) if t.whole else (^f32)(t.ptr)^
}

token_set :: proc(t: Token, v: f32) {
	if t.whole {
		(^u16)(t.ptr)^ = u16(clamp(v + 0.5, 0, 65535))
	} else {
		(^f32)(t.ptr)^ = v
	}
}

@(private)
skip_field :: proc(tag: reflect.Struct_Tag) -> bool {
	v, ok := reflect.struct_tag_lookup(tag, "design")
	return ok && v == "-"
}

// --- files -------------------------------------------------------------------------
//
// A TOML subset: [sections], `key = value`, # comments. Values are numbers,
// "strings", and "#rrggbb" or "#rrggbbaa" colors.
//
//   name = "Console"
//
//   [type]
//   font_title = "Inter-Medium"
//   size_title = 28
//
//   [shape]            Metrics
//   [motion]           Motion, durations in seconds
//
//   [dark]             Theme_Base: background, foreground, accent (required),
//   background = "#0a0c14"      surface, border, text_on_accent, warning, ...
//   [dark.palette]     palette fields set by hand, after the derivation
//   [light] ...

load_design :: proc(path: string, allocator := context.allocator) -> (d: Design, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	dir := os.dir(path)
	return parse_design(string(data), dir, allocator)
}

// Parse a design file. `dir` is where its relative font paths start.
parse_design :: proc(text: string, dir: string = "", allocator := context.allocator) -> (d: Design, ok: bool) {
	d = default_design(allocator)
	d.dir = strings.clone(dir, allocator)
	section := ""
	text := strings.trim_prefix(text, "\ufeff") // a BOM, from Windows editors
	line_no := 0
	reset: [Theme_Mode]bool
	for raw in strings.split_lines_iterator(&text) {
		line_no += 1
		line := strings.trim_space(strip_comment(raw))
		if line == "" {
			continue
		}
		if line[0] == '[' && line[len(line) - 1] == ']' {
			section = strings.trim_space(line[1:len(line) - 1])
			// A mode's first section replaces the built-in colors, overrides
			// too, whichever of [mode] and [mode.palette] comes first.
			switch section {
			case "dark", "dark.palette":
				if !reset[.Dark] {
					d.dark = {base = {mode = .Dark}}
					reset[.Dark] = true
				}
			case "light", "light.palette":
				if !reset[.Light] {
					d.light = {base = {mode = .Light}}
					reset[.Light] = true
				}
			}
			continue
		}
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			fmt.eprintfln("ui: design line %d: expected key = value", line_no)
			continue
		}
		key := strings.trim_space(line[:eq])
		value := unquote(strings.trim_space(line[eq + 1:]))
		known := false
		switch section {
		case "":
			if key == "name" {
				design_set_string(&d.name, value, allocator)
				known = true
			}
		case "type":
			for name, role in ROLE_NAMES {
				if key == strings.concatenate({"font_", name}, context.temp_allocator) {
					design_set_string(&d.fonts[role], value, allocator)
					known = true
				}
			}
			if !known {
				known = set_token(&d.typography, key, value)
			}
		case "shape":
			known = set_token(&d.metrics, key, value)
		case "motion":
			known = set_token(&d.motion, key, value)
		case "dark", "light":
			set := &d.dark if section == "dark" else &d.light
			if c, c_ok := parse_hex(value); c_ok {
				known = set_field(&set.base, Theme_Base, key, c)
			}
		case "dark.palette", "light.palette":
			set := &d.dark if section == "dark.palette" else &d.light
			if c, c_ok := parse_hex(value); c_ok {
				for name, i in palette_field_names() {
					if name == key {
						arr := transmute([PALETTE_LEN]Color)set.overrides
						arr[i] = c
						set.overrides = transmute(Palette)arr
						set.overridden += {i}
						known = true
					}
				}
			}
		}
		if !known {
			fmt.eprintfln("ui: design line %d: unknown or bad [%s] %s = %s", line_no, section, key, value)
		}
	}
	ok = true
	for mode in Theme_Mode {
		b := color_set(&d, mode).base
		ok &&= b.background.a > 0 && b.foreground.a > 0 && b.accent.a > 0
	}
	if !ok {
		fmt.eprintln("ui: design needs background, foreground and accent for both dark and light")
	}
	return
}

// Written to a temporary file and renamed over `path`, so a crash or a full
// disk never leaves a half-written design for a hot-reloading reader.
save_design :: proc(d: Design, path: string) -> bool {
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, design_to_toml(d, context.temp_allocator)) != nil {
		os.remove(tmp)
		return false
	}
	if os.rename(tmp, path) != nil {
		os.remove(tmp)
		return false
	}
	return true
}

design_to_toml :: proc(d: Design, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "# odin-ui design: load with ui.load_design, see ui/design.odin.\n\n")
	fmt.sbprintf(&b, "name = %q\n", d.name)

	d := d
	strings.write_string(&b, "\n[type]\n")
	for name, role in ROLE_NAMES {
		fmt.sbprintf(&b, "font_%s = %q\n", name, d.fonts[role])
	}
	write_tokens(&b, tokens(&d.typography))
	strings.write_string(&b, "\n[shape]\n")
	write_tokens(&b, tokens(&d.metrics))
	strings.write_string(&b, "\n[motion]\n")
	write_tokens(&b, tokens(&d.motion))

	for mode in Theme_Mode {
		name := "dark" if mode == .Dark else "light"
		set := color_set(&d, mode)
		fmt.sbprintf(&b, "\n[%s]\n", name)
		for f in reflect.struct_fields_zipped(Theme_Base) {
			if skip_field(f.tag) || f.type.id != Color {
				continue
			}
			c := (^Color)(uintptr(&set.base) + f.offset)^
			if c.a > 0 {
				fmt.sbprintf(&b, "%s = \"%s\"\n", f.name, hex(c))
			}
		}
		if set.overridden != {} {
			fmt.sbprintf(&b, "\n[%s.palette]\n", name)
			over := transmute([PALETTE_LEN]Color)set.overrides
			for field, i in palette_field_names() {
				if i in set.overridden {
					fmt.sbprintf(&b, "%s = \"%s\"\n", field, hex(over[i]))
				}
			}
		}
	}
	return strings.to_string(b)
}

// "#rrggbb", or "#rrggbbaa" when not opaque. Temp allocated.
hex :: proc(c: Color) -> string {
	r, g, bl, a := u8(clamp(c.r + 0.5, 0, 255)), u8(clamp(c.g + 0.5, 0, 255)), u8(clamp(c.b + 0.5, 0, 255)), u8(clamp(c.a + 0.5, 0, 255))
	if a == 255 {
		return fmt.tprintf("#%02x%02x%02x", r, g, bl)
	}
	return fmt.tprintf("#%02x%02x%02x%02x", r, g, bl, a)
}

parse_hex :: proc(s: string) -> (c: Color, ok: bool) {
	s := strings.trim_prefix(s, "#")
	if len(s) != 6 && len(s) != 8 {
		return
	}
	for ch in s {
		if !(ch >= '0' && ch <= '9' || ch >= 'a' && ch <= 'f' || ch >= 'A' && ch <= 'F') {
			return
		}
	}
	v, v_ok := strconv.parse_u64_of_base(s, 16)
	if !v_ok {
		return
	}
	if len(s) == 6 {
		v = v << 8 | 0xff
	}
	return {f32(v >> 24 & 0xff), f32(v >> 16 & 0xff), f32(v >> 8 & 0xff), f32(v & 0xff)}, true
}

@(private)
write_tokens :: proc(b: ^strings.Builder, ts: []Token) {
	for t in ts {
		if t.whole {
			fmt.sbprintf(b, "%s = %d\n", t.key, int(token_get(t)))
		} else {
			fmt.sbprintf(b, "%s = %v\n", t.key, token_get(t))
		}
	}
}

@(private)
set_token :: proc(ptr: ^$T, key, value: string) -> bool {
	for t in tokens(ptr) {
		if t.key == key {
			v, ok := strconv.parse_f32(value)
			if !ok || math.is_nan(v) || math.is_inf(v) {
				return false
			}
			// Held to the editor's range: a 0px font or a 0s spring breaks things.
			if t.hi > t.lo {
				v = clamp(v, t.lo, t.hi)
			}
			token_set(t, v)
			return true
		}
	}
	return false
}

@(private)
set_field :: proc(ptr: rawptr, T: typeid, key: string, c: Color) -> bool {
	f := reflect.struct_field_by_name(T, key)
	if f.type == nil || f.type.id != Color || skip_field(f.tag) {
		return false
	}
	(^Color)(uintptr(ptr) + f.offset)^ = c
	return true
}

// Drop a # comment, but not a # inside quotes (colors) or after a \ there.
@(private)
strip_comment :: proc(line: string) -> string {
	quoted, escaped := false, false
	for ch, i in line {
		if escaped {
			escaped = false
			continue
		}
		switch ch {
		case '\\':
			escaped = quoted
		case '"':
			quoted = !quoted
		case '#':
			if !quoted {
				return line[:i]
			}
		}
	}
	return line
}

// A "string" with its escapes undone (the writer uses %q), temp allocated.
// Anything else comes back as it is.
@(private)
unquote :: proc(s: string) -> string {
	if len(s) >= 2 && s[0] == '"' && s[len(s) - 1] == '"' {
		if res, _, ok := strconv.unquote_string(s, context.temp_allocator); ok {
			return res
		}
		return s[1:len(s) - 1]
	}
	return s
}
