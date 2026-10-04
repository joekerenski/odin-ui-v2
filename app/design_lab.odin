package main

// The Design tab: edit the look and feel live and save it as a design file,
// which another project loads with ui.load_design. Designs are the .toml
// files in designs/ next to the binary (or the working directory). The one
// being edited reloads when its file changes on disk and has no unsaved
// edits, so a text editor works as well as the panel.
//
// The panel edits a working copy; every change is applied at once. Save
// writes it back, Save as new writes a new file, Revert drops the edits.

import ui "../ui"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:time"

Font_Choice :: struct {
	label: string, // owned
	face:  string, // owned; what a design file says
}

Lab :: struct {
	dir:       string,          // designs/, absolute; may not exist yet
	fonts_dir: string,          // fonts/, absolute
	files:     [dynamic]string, // stems of designs/*.toml, sorted
	current:   int,             // index into files; -1 is the built-in design
	design:    ui.Design,       // the working copy, applied
	saved:     string,          // the design as last loaded or saved, as TOML
	applied:   string,          // as last applied, to apply only changes
	mtime:     time.Time,
	checked:   time.Tick,
	fonts:     [dynamic]Font_Choice,
	menus:     [len(ui.Type_Role) + 1]ui.Dropdown,
	colors:    int, // 0: base colors, 1: palette
	pick:      int, // the color row being edited
	status:    string, // owned
}

@(private = "file")
CHECK_EVERY :: 500 * time.Millisecond

// `start` names a design in designs/ ("" for console, or the built-in one).
lab_init :: proc(lab: ^Lab, start: string) {
	exe, _ := os.get_executable_directory(context.temp_allocator)
	cwd, _ := os.get_working_directory(context.temp_allocator)
	lab.dir = find_dir("designs", exe, cwd)
	lab.fonts_dir = find_dir("fonts", exe, cwd)
	lab.current = -1
	scan_designs(lab)
	scan_fonts(lab)

	want := start if start != "" else "console"
	idx, found := slice.linear_search(lab.files[:], want)
	if !found && start != "" {
		fmt.eprintfln("design %q not found in %s", start, lab.dir)
	}
	if !lab_load(lab, idx if found else -1) {
		// Never run on a zeroed design: fall back to the built-in one.
		status := strings.clone(lab.status, context.temp_allocator)
		lab_load(lab, -1)
		set_status(lab, status)
	}
}

lab_destroy :: proc(lab: ^Lab) {
	ui.design_destroy(&lab.design)
	delete(lab.dir)
	delete(lab.fonts_dir)
	for f in lab.files {
		delete(f)
	}
	delete(lab.files)
	for f in lab.fonts {
		delete(f.label)
		delete(f.face)
	}
	delete(lab.fonts)
	delete(lab.saved)
	delete(lab.applied)
	delete(lab.status)
}

// Once per frame, on every tab: pick up the file changing on disk, and
// apply the working copy when it changed. `th` decides whether the design's
// colors show (Dark or Light) or the system's.
lab_update :: proc(lab: ^Lab, th: ^Theming) {
	if lab.checked == {} || time.tick_since(lab.checked) >= CHECK_EVERY {
		lab.checked = time.tick_now()
		scan_designs(lab)
		if lab.current >= 0 {
			if mt, err := os.modification_time_by_path(design_path(lab, lab.current)); err == nil && mt != lab.mtime {
				if lab_dirty(lab) {
					lab.mtime = mt
					set_status(lab, "Changed on disk. Save to overwrite, or Revert to load it.")
				} else if lab_load(lab, lab.current) {
					set_status(lab, "Reloaded from disk.")
				}
			}
		}
	}
	text := ui.design_to_toml(lab.design, context.temp_allocator)
	if text != lab.applied {
		mode: Maybe(ui.Theme_Mode)
		#partial switch th.source {
		case .Dark:
			mode = .Dark
		case .Light:
			mode = .Light
		}
		ui.apply_design(lab.design, mode)
		delete(lab.applied)
		lab.applied = strings.clone(text)
	}
}

lab_dirty :: proc(lab: ^Lab) -> bool {
	return ui.design_to_toml(lab.design, context.temp_allocator) != lab.saved
}

// The editor, as the side panel of the Design tab.
lab_panel :: proc(lab: ^Lab, th: ^Theming) {
	if !ui.panel_begin("LabPanel") {
		return
	}
	defer ui.panel_end("LabPanel")

	ui.title("Design")
	ui.dim(lab.status if lab.status != "" else "Edits apply at once. Save writes the file.")

	file_section(lab)
	ui.divider("lab_div0")
	color_section(lab, th)
	ui.divider("lab_div1")
	type_section(lab)
	ui.divider("lab_div2")
	ui.section("SHAPE")
	token_sliders("lab_shape", ui.tokens(&lab.design.metrics))
	ui.divider("lab_div3")
	ui.section("MOTION")
	token_sliders("lab_motion", ui.tokens(&lab.design.motion))
}

// --- sections ---------------------------------------------------------------------

@(private = "file")
file_section :: proc(lab: ^Lab) {
	ui.section("FILE")
	names := make([dynamic]string, context.temp_allocator)
	append(&names, "Built-in")
	append(&names, ..lab.files[:])
	picked := ui.dropdown(&lab.menus[0], "lab_file", "Design", names[:], lab.current + 1) - 1
	if picked != lab.current {
		lab_load(lab, picked)
	}
	dirty := lab_dirty(lab)
	if ui.row_begin("lab_file_row", {gap = ui.theme.gap_md}) {
		if ui.button("lab_save", "Save", {accent = dirty, disabled = !dirty && lab.current >= 0}) {
			if lab.current >= 0 {
				lab_save(lab, lab.current)
			} else {
				lab_save_new(lab)
			}
		}
		if ui.button("lab_save_new", "Save as new") {
			lab_save_new(lab)
		}
		if ui.button("lab_revert", "Revert", {disabled = !dirty}) {
			lab_load(lab, lab.current)
			set_status(lab, "Reverted.")
		}
		ui.element_end()
	}
	if ui.button("lab_copy", "Copy as TOML") {
		ui.set_clipboard(ui.design_to_toml(lab.design, context.temp_allocator))
		set_status(lab, "Copied the design to the clipboard.")
	}
}

// The palette field a base color shows up as.
@(private = "file")
palette_name :: proc(base_field: string) -> string {
	switch base_field {
	case "background":
		return "bg"
	case "foreground":
		return "text"
	}
	return base_field
}

@(private = "file")
REQUIRED := []string{"background", "foreground", "accent"}

@(private = "file")
color_section :: proc(lab: ^Lab, th: ^Theming) {
	ui.section("COLORS")
	mode_idx := -1
	#partial switch th.source {
	case .Dark:
		mode_idx = 0
	case .Light:
		mode_idx = 1
	}
	if picked := ui.tabs("lab_mode", {"Dark", "Light"}, mode_idx); picked != mode_idx {
		theming_set(th, .Dark if picked == 0 else .Light)
	}
	if mode_idx < 0 {
		ui.dim("The system's colors are showing. Pick Dark or Light to edit the design's.")
		return
	}
	set := ui.color_set(&lab.design, .Dark if mode_idx == 0 else .Light)
	palette := ui.palette_of(set^)
	pal_names := ui.palette_field_names()
	pal := transmute([ui.PALETTE_LEN]ui.Color)palette

	if picked := ui.tabs("lab_color_list", {"Base", "Palette"}, lab.colors); picked != lab.colors {
		lab.colors = picked
		lab.pick = 0
	}

	Row :: struct {
		name:    string,
		color:   ui.Color, // what shows
		note:    string,
		ptr:     ^ui.Color, // where an edit goes
		clear:   string,    // label of the button that undoes the edit, "" for none
	}
	rows := make([dynamic]Row, context.temp_allocator)
	if lab.colors == 0 {
		for f in reflect.struct_fields_zipped(ui.Theme_Base) {
			if f.type.id != ui.Color {
				continue
			}
			ptr := (^ui.Color)(uintptr(&set.base) + f.offset)
			idx, _ := slice.linear_search(pal_names, palette_name(f.name))
			row := Row{name = f.name, color = ptr^, ptr = ptr}
			if ptr.a > 0 {
				row.note = ui.hex(ptr^)
				if !slice.contains(REQUIRED, f.name) {
					row.clear = "Auto"
				}
			} else {
				row.color = pal[idx]
				row.note = "auto"
			}
			append(&rows, row)
		}
	} else {
		over := (^[ui.PALETTE_LEN]ui.Color)(&set.overrides)
		for name, i in pal_names {
			row := Row{name = name, color = pal[i], ptr = &over[i]}
			if i in set.overridden {
				row.note = ui.hex(pal[i])
				row.clear = "Derive"
			} else {
				row.note = "derived"
			}
			append(&rows, row)
		}
	}
	lab.pick = clamp(lab.pick, 0, len(rows) - 1)

	for r, i in rows {
		id := fmt.tprintf("lab_color_%d", i)
		hot, held := ui.press_state(id)
		bg := ui.feedback(id, ui.Color{}, ui.theme.surface_hot, hot, held)
		if i == lab.pick {
			bg = ui.theme.surface
		}
		if ui.row_begin(id, {padding = 5, gap = ui.theme.gap_md, bg = bg, radius = ui.theme.radius_sm}) {
			ui.swatch(fmt.tprintf("%s_sw", id), r.color, 18, 18, outline = ui.theme.border)
			if ui.row_begin(fmt.tprintf("%s_name", id)) {
				ui.text(r.name, ui.theme.font_small, ui.theme.size_small, ui.theme.text)
				ui.element_end()
			}
			ui.dim(r.note)
			ui.element_end()
		}
		if ui.clicked(id) {
			lab.pick = i
		}
	}

	r := rows[lab.pick]
	if c, changed := ui.color_picker("lab_picker", r.color); changed {
		c.a = r.color.a if r.color.a > 0 else 255
		r.ptr^ = c
		if lab.colors == 1 {
			set.overridden += {lab.pick}
		}
	}
	if r.clear != "" && ui.button("lab_color_clear", fmt.tprintf("%s: %s", r.clear, r.name)) {
		if lab.colors == 0 {
			r.ptr^ = {}
		} else {
			set.overridden -= {lab.pick}
		}
	}
}

@(private = "file")
type_section :: proc(lab: ^Lab) {
	ui.section("TYPE")
	labels := make([dynamic]string, context.temp_allocator)
	for f in lab.fonts {
		append(&labels, f.label)
	}
	sizes := ui.tokens(&lab.design.typography)
	for role in ui.Type_Role {
		face := lab.design.fonts[role]
		cur := font_index(lab, face)
		if cur < 0 {
			// A face the list doesn't have (typed into the file): show it.
			append(&labels, face)
			cur = len(labels) - 1
		}
		id := fmt.tprintf("lab_font_%v", role)
		picked := ui.dropdown(&lab.menus[int(role) + 1], id, "Font", labels[:], cur)
		if picked != cur && picked < len(lab.fonts) {
			ui.design_set_string(&lab.design.fonts[role], lab.fonts[picked].face)
		}
		if int(role) < len(sizes) {
			t := sizes[int(role)]
			v := ui.slider(fmt.tprintf("lab_size_%v", role), fmt.tprintf("%s size", t.label), ui.token_get(t), t.lo, t.hi, "%.0f")
			ui.token_set(t, v)
		}
		resize(&labels, len(lab.fonts))
	}
}

// A slider per token; seconds show as milliseconds. A value is snapped to
// the slider's step only when the slider moves it, so opening the panel
// doesn't rewrite a hand-edited 0.125 (and make the design dirty).
@(private = "file")
token_sliders :: proc(prefix: string, ts: []ui.Token) {
	for t in ts {
		id := fmt.tprintf("%s_%s", prefix, t.key)
		cur := ui.token_get(t)
		if t.unit == "ms" {
			if v := ui.slider(id, t.label, cur * 1000, t.lo * 1000, t.hi * 1000, "%.0f ms"); v != cur * 1000 {
				ui.token_set(t, f32(int(v + 0.5)) / 1000)
			}
		} else if t.whole {
			if v := ui.slider(id, t.label, cur, t.lo, t.hi, "%.0f"); v != cur {
				ui.token_set(t, v)
			}
		} else if t.hi - t.lo <= 2 {
			if v := ui.slider(id, t.label, cur, t.lo, t.hi, "%.2f"); v != cur {
				ui.token_set(t, f32(int(v * 100 + 0.5)) / 100)
			}
		} else {
			if v := ui.slider(id, t.label, cur, t.lo, t.hi, "%.0f"); v != cur {
				ui.token_set(t, f32(int(v + 0.5)))
			}
		}
	}
}

// --- files ------------------------------------------------------------------------

// False when the file doesn't parse; the working copy stays as it was.
lab_load :: proc(lab: ^Lab, index: int) -> bool {
	d: ui.Design
	ok := true
	if index < 0 {
		d = ui.default_design()
		ui.design_set_string(&d.dir, lab.dir)
		if len(lab.fonts) > 0 {
			for &f in d.fonts {
				ui.design_set_string(&f, lab.fonts[0].face)
			}
		}
		lab.mtime = {}
	} else {
		path := design_path(lab, index)
		d, ok = ui.load_design(path)
		if !ok {
			ui.design_destroy(&d)
			set_status(lab, fmt.tprintf("Could not load %s.toml; see the terminal.", lab.files[index]))
			if index == lab.current {
				// A bad reload: try again on the next change, not every poll.
				lab.mtime, _ = os.modification_time_by_path(path)
			}
			return false
		}
		lab.mtime, _ = os.modification_time_by_path(path)
	}
	ui.design_destroy(&lab.design)
	lab.design = d
	lab.current = index
	delete(lab.saved)
	lab.saved = ui.design_to_toml(lab.design)
	set_status(lab, "")
	return true
}

@(private = "file")
lab_save :: proc(lab: ^Lab, index: int) {
	_ = os.make_directory_all(lab.dir)
	path := design_path(lab, index)
	if !ui.save_design(lab.design, path) {
		set_status(lab, fmt.tprintf("Could not write %s.", path))
		return
	}
	delete(lab.saved)
	lab.saved = ui.design_to_toml(lab.design)
	lab.mtime, _ = os.modification_time_by_path(path)
	set_status(lab, fmt.tprintf("Saved %s.toml.", lab.files[index]))
}

// A new file named after the design, numbered if taken. The design's name
// follows, so the two match.
@(private = "file")
lab_save_new :: proc(lab: ^Lab) {
	// Taken ignores case (APFS does) and checks the disk, not just the list.
	taken :: proc(lab: ^Lab, base: string) -> bool {
		for f in lab.files {
			if strings.equal_fold(f, base) {
				return true
			}
		}
		p, _ := os.join_path({lab.dir, fmt.tprintf("%s.toml", base)}, context.temp_allocator)
		return os.exists(p)
	}
	base := slug(lab.design.name)
	for n := 2; taken(lab, base); n += 1 {
		base = fmt.tprintf("%s-%d", slug(lab.design.name), n)
	}
	ui.design_set_string(&lab.design.name, base)
	append(&lab.files, strings.clone(base))
	slice.sort(lab.files[:])
	idx, _ := slice.linear_search(lab.files[:], base)
	lab.current = idx
	lab_save(lab, idx)
}

@(private = "file")
design_path :: proc(lab: ^Lab, index: int) -> string {
	p, _ := os.join_path({lab.dir, fmt.tprintf("%s.toml", lab.files[index])}, context.temp_allocator)
	return p
}

// The design files on disk now; the one being edited stays selected.
@(private = "file")
scan_designs :: proc(lab: ^Lab) {
	cur := lab.files[lab.current] if lab.current >= 0 && lab.current < len(lab.files) else ""
	cur = strings.clone(cur, context.temp_allocator)
	for f in lab.files {
		delete(f)
	}
	clear(&lab.files)
	if infos, err := os.read_all_directory_by_path(lab.dir, context.temp_allocator); err == nil {
		for fi in infos {
			if fi.type == .Regular && strings.has_suffix(fi.name, ".toml") {
				append(&lab.files, strings.clone(strings.trim_suffix(fi.name, ".toml")))
			}
		}
	}
	slice.sort(lab.files[:])
	if cur != "" {
		idx, found := slice.linear_search(lab.files[:], cur)
		if !found {
			// Deleted on disk: keep editing it; Save writes it back.
			append(&lab.files, strings.clone(cur))
			slice.sort(lab.files[:])
			idx, _ = slice.linear_search(lab.files[:], cur)
		}
		lab.current = idx
	}
}

// Registered fonts, then the .ttf and .otf files in fonts/ that aren't
// registered under their name. A file's face is its path from designs/.
@(private = "file")
scan_fonts :: proc(lab: ^Lab) {
	registered := ui.registered_fonts()
	for name in registered {
		append(&lab.fonts, Font_Choice{label = strings.clone(name), face = strings.clone(name)})
	}
	infos, err := os.read_all_directory_by_path(lab.fonts_dir, context.temp_allocator)
	if err != nil {
		return
	}
	for fi in infos {
		ext := strings.to_lower(os.ext(fi.name), context.temp_allocator)
		stem := os.stem(fi.name)
		if fi.type != .Regular || (ext != ".ttf" && ext != ".otf") || slice.contains(registered, stem) {
			continue
		}
		rel, rel_err := os.get_relative_path(lab.dir, fi.fullpath, context.temp_allocator)
		if rel_err != nil {
			rel = fi.fullpath
		}
		append(&lab.fonts, Font_Choice{label = strings.clone(stem), face = strings.clone(rel)})
	}
}

@(private = "file")
font_index :: proc(lab: ^Lab, face: string) -> int {
	if face == "" && len(lab.fonts) > 0 {
		return 0
	}
	for f, i in lab.fonts {
		if f.face == face {
			return i
		}
	}
	return -1
}

@(private = "file")
set_status :: proc(lab: ^Lab, s: string) {
	delete(lab.status)
	lab.status = strings.clone(s)
}

// A directory next to the binary, else in the working directory. Absolute.
@(private = "file")
find_dir :: proc(name, exe, cwd: string) -> string {
	for base in ([]string{exe, cwd}) {
		p, _ := os.join_path({base, name}, context.temp_allocator)
		if os.is_dir(p) {
			return strings.clone(p)
		}
	}
	p, _ := os.join_path({exe, name}, context.allocator)
	return p
}

// "Soft Glass" -> "soft-glass".
@(private = "file")
slug :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	dash := false
	for r in strings.to_lower(name, context.temp_allocator) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			strings.write_rune(&b, r)
			dash = false
		} else if !dash && strings.builder_len(b) > 0 {
			strings.write_byte(&b, '-')
			dash = true
		}
	}
	s := strings.trim_right(strings.to_string(b), "-")
	return s if s != "" else "design"
}
