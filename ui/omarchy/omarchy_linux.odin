package omarchy

// The active theme lives in ~/.local/state/omarchy/current/theme/. Its
// colors.toml is a flat `key = "#rrggbb"` palette. omarchy-theme-set replaces
// that directory, then writes theme.name next to it, so a new theme.name
// mtime means a complete new theme.
//
// Only the fields that mean the same thing in every theme are read. The
// shade variants do not: `lighter_background` is darker than `background` in
// Catppuccin Latte, `light_foreground` is dimmer than the text in Everforest
// and brighter in Tokyo Night. ui.palette_from_base mixes the shades instead.

import ui ".."
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

@(private)
CHECK_EVERY :: 500 * time.Millisecond

@(private)
s_checked: time.Tick

@(private)
s_mtime: time.Time

// The active theme. `name` is allocated with `allocator`. ok = false when
// there is no Omarchy theme, or it lacks background, foreground, or accent.
load :: proc(allocator := context.allocator) -> (t: Theme, ok: bool) {
	dir := state_dir(context.temp_allocator)
	data, err := os.read_entire_file(strings.concatenate({dir, "/theme/colors.toml"}, context.temp_allocator), context.temp_allocator)
	if err != nil {
		return
	}
	t.base, ok = parse_colors(string(data))
	if !ok {
		return
	}
	name_path := strings.concatenate({dir, "/theme.name"}, context.temp_allocator)
	if raw, name_err := os.read_entire_file(name_path, context.temp_allocator); name_err == nil {
		t.name = pretty_name(strings.trim_space(string(raw)), allocator)
	}
	if fi, stat_err := os.stat(name_path, context.temp_allocator); stat_err == nil {
		s_mtime = fi.modification_time
	}
	return
}

// True once each time the theme changes. Checks the disk at most every
// 500ms, so it is cheap to call every frame.
changed :: proc() -> bool {
	if s_checked != {} && time.tick_since(s_checked) < CHECK_EVERY {
		return false
	}
	s_checked = time.tick_now()
	name_path := strings.concatenate({state_dir(context.temp_allocator), "/theme.name"}, context.temp_allocator)
	fi, err := os.stat(name_path, context.temp_allocator)
	if err != nil || fi.modification_time == s_mtime {
		return false
	}
	s_mtime = fi.modification_time
	return true
}

@(private)
state_dir :: proc(allocator := context.allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	return strings.concatenate({home, "/.local/state/omarchy/current"}, allocator)
}

@(private)
parse_colors :: proc(text: string) -> (b: ui.Theme_Base, ok: bool) {
	text := text
	for line in strings.split_lines_iterator(&text) {
		line := strings.trim_space(line)
		if line == "" || line[0] == '#' {
			continue
		}
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			continue
		}
		key := strings.trim_space(line[:eq])
		val := strings.trim_space(line[eq + 1:])
		if len(val) > 0 && val[0] == '"' {
			if end := strings.index_byte(val[1:], '"'); end >= 0 {
				val = val[1:end + 1]
			}
		}
		switch key {
		case "mode":
			b.mode = .Light if val == "light" else .Dark
		case "background":
			b.background = hex(val)
		case "foreground":
			b.foreground = hex(val)
		case "accent":
			b.accent = hex(val)
		case "selection":
			b.surface = hex(val)
		case "muted":
			b.border = hex(val)
		case "yellow":
			b.warning = hex(val)
		case "red":
			b.danger = hex(val)
		case "green":
			b.success = hex(val)
		}
	}
	ok = b.background.a > 0 && b.foreground.a > 0 && b.accent.a > 0
	return
}

// "#rrggbb" or "#rrggbbaa"; anything else is alpha 0, which the base reads
// as "derive it".
@(private)
hex :: proc(s: string) -> ui.Color {
	s := strings.trim_prefix(s, "#")
	if len(s) != 6 && len(s) != 8 {
		return {}
	}
	v, ok := strconv.parse_u64_of_base(s, 16)
	if !ok {
		return {}
	}
	if len(s) == 6 {
		v = v << 8 | 0xff
	}
	return {f32(v >> 24 & 0xff), f32(v >> 16 & 0xff), f32(v >> 8 & 0xff), f32(v & 0xff)}
}

// "catppuccin-latte" -> "Catppuccin Latte", like `omarchy theme current`.
@(private)
pretty_name :: proc(slug: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	up := true
	for r in slug {
		if r == '-' {
			strings.write_byte(&b, ' ')
			up = true
			continue
		}
		if up && r >= 'a' && r <= 'z' {
			strings.write_rune(&b, r - 32)
		} else {
			strings.write_rune(&b, r)
		}
		up = false
	}
	return strings.to_string(b)
}
