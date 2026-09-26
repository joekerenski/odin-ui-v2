package main

// The Showcase tab: one scrollable column of cards, one per thing worth
// trying. Add a card to play with a widget; the state lives in `Showcase`.

import ui "../ui"
import "core:fmt"

Showcase :: struct {
	clicks:   int,
	toggled:  bool,
	segment:  int,
	rgb:      [3]f32,
	alpha:    f32,
	menu:     ui.Dropdown,
	choice:   int,
	page:     int,
	selected: int, // list row, -1 none
}

showcase_init :: proc() -> Showcase {
	return {rgb = {110, 170, 255}, alpha = 1, choice = 1, page = 1, selected = -1}
}

@(private = "file")
SEGMENTS := []string{"Day", "Week", "Month"}

@(private = "file")
EASINGS := []string{"Linear", "Ease in", "Ease out", "Ease in-out", "Spring"}

@(private = "file")
PAGES :: 12

@(private = "file")
LIST_ROWS :: 24

build_showcase :: proc(sc: ^Showcase, th: ^Theming) {
	if !ui.scroll_begin("Showcase") {
		return
	}
	defer ui.scroll_end("Showcase")

	if ui.card_begin("sc_intro", "UI showcase", "Every widget in one place. Scroll with the wheel or drag the thumb on the right.") {
		ui.element_end()
	}

	theme_card(th)

	if ui.card_begin("sc_buttons", "Buttons", "Default, accent, and disabled. Width is shared across the row.") {
		if ui.row_begin("sc_buttons_row", {gap = ui.theme.gap_md}) {
			if ui.button("sc_btn", "Click me") {
				sc.clicks += 1
			}
			if ui.button("sc_btn_accent", "Accent", {accent = true}) {
				sc.clicks += 10
			}
			ui.button("sc_btn_off", "Disabled", {disabled = true})
			ui.element_end()
		}
		ui.dim(fmt.tprintf("clicks: %d   (accent counts 10)", sc.clicks))
		ui.element_end()
	}

	if ui.card_begin("sc_choice", "Toggle and segments") {
		if ui.row_begin("sc_choice_row", {gap = ui.theme.gap_md}) {
			sc.toggled = ui.toggle("sc_toggle", sc.toggled ? "ON" : "OFF", sc.toggled)
			sc.segment = ui.tabs("sc_segments", SEGMENTS, sc.segment)
			ui.element_end()
		}
		ui.dim(fmt.tprintf("toggle %v, segment %s", sc.toggled, SEGMENTS[sc.segment]))
		ui.element_end()
	}

	if ui.card_begin("sc_sliders", "Sliders", "An RGBA mixer; the swatch shows the result.") {
		if ui.row_begin("sc_sliders_row", {gap = ui.theme.gap_md * 2}) {
			if ui.column_begin("sc_sliders_col", {gap = ui.theme.gap_md}) {
				sc.rgb.r = ui.slider("sc_r", "Red", sc.rgb.r, 0, 255, "%.0f")
				sc.rgb.g = ui.slider("sc_g", "Green", sc.rgb.g, 0, 255, "%.0f")
				sc.rgb.b = ui.slider("sc_b", "Blue", sc.rgb.b, 0, 255, "%.0f")
				sc.alpha = ui.slider("sc_a", "Alpha", sc.alpha, 0, 1, "%.2f")
				ui.element_end()
			}
			mixed := ui.Color{sc.rgb.r, sc.rgb.g, sc.rgb.b, sc.alpha * 255}
			ui.swatch("sc_mix", mixed, 160, 160, ui.theme.radius_md)
			ui.element_end()
		}
		ui.element_end()
	}

	if ui.card_begin("sc_dropdown", "Dropdown", "The menu floats above everything and closes on an outside click.") {
		sc.choice = ui.dropdown(&sc.menu, "sc_menu", "Pick one", EASINGS, sc.choice)
		ui.dim(fmt.tprintf("selected: %s", EASINGS[sc.choice]))
		ui.element_end()
	}

	if ui.card_begin("sc_pager", "Icon buttons", "A pager.") {
		if ui.row_begin("sc_pager_row", {gap = ui.theme.gap_md}) {
			if ui.icon_button("sc_prev", .ChevronLeft) && sc.page > 1 {
				sc.page -= 1
			}
			ui.body(fmt.tprintf("page %d of %d", sc.page, PAGES))
			if ui.icon_button("sc_next", .ChevronRight) && sc.page < PAGES {
				sc.page += 1
			}
			ui.element_end()
		}
		ui.element_end()
	}

	if ui.card_begin("sc_type", "Typography") {
		ui.title("Title, 28")
		ui.body("Body, 16: the quick brown fox jumps over the lazy dog.")
		ui.dim("Dim, 14: secondary text and hints.")
		ui.section("SECTION, 14")
		ui.body("Latin-1 and symbols: café, naïve, 25 €, ← ↑ → ↓, ✓ ×, “quotes” – dashes …")
		ui.element_end()
	}

	if ui.card_begin("sc_palette", "Theme palette") {
		Named :: struct {
			name:  string,
			color: ui.Color,
		}
		t := ui.theme
		palette := [?]Named{
			{"bg", t.bg}, {"panel", t.panel}, {"surface", t.surface}, {"border", t.border},
			{"text", t.text}, {"dim", t.text_dim}, {"accent", t.accent}, {"warning", t.warning},
			{"danger", t.danger}, {"success", t.success},
		}
		if ui.row_begin("sc_palette_row", {gap = 6}) {
			for p, i in palette {
				ui.swatch(fmt.tprintf("sc_pal_%d", i), p.color, 0, 36, outline = t.border)
			}
			ui.element_end()
		}
		if ui.row_begin("sc_palette_names", {gap = 6}) {
			for p, i in palette {
				if ui.row_begin(fmt.tprintf("sc_pal_name_%d", i)) {
					ui.dim(p.name)
					ui.element_end()
				}
			}
			ui.element_end()
		}
		ui.element_end()
	}

	if ui.card_begin("sc_list", "A long list", "Enough rows to scroll. Click one to select it.") {
		for i in 0 ..< LIST_ROWS {
			id := fmt.tprintf("sc_row_%d", i)
			bg := ui.Color{}
			if i == sc.selected {
				bg = ui.theme.surface
			} else if ui.hovered(id) {
				bg = ui.theme.surface_hot
			}
			if ui.row_begin(id, {padding = 8, bg = bg, radius = ui.theme.radius_sm}) {
				ui.body(fmt.tprintf("Row %d", i + 1))
				ui.element_end()
			}
			if ui.clicked(id) {
				sc.selected = -1 if sc.selected == i else i
			}
		}
		ui.element_end()
	}
}

@(private = "file")
theme_card :: proc(th: ^Theming) {
	sub := "Built-in palettes. On Omarchy or macOS, the system theme shows up here too."
	if th.omarchy {
		sub = "Follows `omarchy theme set` live, or pick a built-in palette."
	} else if th.system {
		sub = "Follows the macOS appearance and accent color live, or pick a built-in palette."
	}
	if !ui.card_begin("sc_theme", "Theme", sub) {
		return
	}
	labels := make([dynamic]string, context.temp_allocator)
	sources := make([dynamic]Theme_Source, context.temp_allocator)
	if th.omarchy {
		append(&labels, fmt.tprintf("Omarchy · %s", th.omarchy_name))
		append(&sources, Theme_Source.Omarchy)
	}
	if th.system {
		append(&labels, fmt.tprintf("System · %s", th.system_name))
		append(&sources, Theme_Source.System)
	}
	append(&labels, "Dark", "Light")
	append(&sources, Theme_Source.Dark, Theme_Source.Light)
	selected := 0
	for s, i in sources {
		if s == th.source {
			selected = i
		}
	}
	if picked := ui.tabs("sc_theme_tabs", labels[:], selected); picked != selected {
		theming_set(th, sources[picked])
	}
	ui.element_end()
}
