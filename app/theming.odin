package main

// Where the colors come from: the active Omarchy theme (Linux, when
// Omarchy is installed), or one of the built-in palettes. Following Omarchy
// is the default when it is there; the Showcase's Theme card switches.

import ui "../ui"
import "../ui/omarchy"

Theme_Source :: enum {
	Omarchy,
	Dark,
	Light,
}

Theming :: struct {
	source:       Theme_Source,
	omarchy:      bool,   // an Omarchy theme was found
	omarchy_name: string, // "Everforest"
}

// Seconds for a palette cross-fade.
THEME_FADE :: 0.25

theming_init :: proc(th: ^Theming) {
	th.source = .Dark
	if theming_load_omarchy(th, 0) {
		th.source = .Omarchy
	}
}

theming_destroy :: proc(th: ^Theming) {
	delete(th.omarchy_name)
}

// Once per frame: pick up `omarchy theme set` while following Omarchy.
theming_update :: proc(th: ^Theming) {
	if th.source == .Omarchy && omarchy.changed() {
		theming_load_omarchy(th, THEME_FADE)
	}
}

theming_set :: proc(th: ^Theming, source: Theme_Source, fade: f32 = THEME_FADE) {
	if source == th.source {
		return
	}
	switch source {
	case .Omarchy:
		if !theming_load_omarchy(th, fade) {
			return
		}
	case .Dark:
		ui.set_palette(ui.PALETTE_DARK, fade)
	case .Light:
		ui.set_palette(ui.palette_from_base(ui.BASE_LIGHT), fade)
	}
	th.source = source
}

@(private = "file")
theming_load_omarchy :: proc(th: ^Theming, fade: f32) -> bool {
	t, ok := omarchy.load()
	if !ok {
		return false
	}
	delete(th.omarchy_name)
	th.omarchy_name = t.name
	th.omarchy = true
	ui.set_palette(ui.palette_from_base(t.base), fade)
	return true
}
