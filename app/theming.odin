package main

// Where the colors come from: the active Omarchy theme (Linux, when
// Omarchy is installed), the macOS appearance, or one of the built-in
// palettes. Following the platform's theme is the default when there is
// one; the Showcase's Theme card switches.

import ui "../ui"
import "../ui/appearance"
import "../ui/omarchy"

Theme_Source :: enum {
	Omarchy,
	System, // macOS appearance and accent
	Dark,
	Light,
}

Theming :: struct {
	source:       Theme_Source,
	omarchy:      bool,   // an Omarchy theme was found
	omarchy_name: string, // "Everforest"
	system:       bool,   // the macOS appearance is readable
	system_name:  string, // "Dark" or "Light", static
}

// Seconds for a palette cross-fade.
THEME_FADE :: 0.25

theming_init :: proc(th: ^Theming) {
	th.source = .Dark
	if theming_load_omarchy(th, 0) {
		th.source = .Omarchy
	} else if theming_load_system(th, 0) {
		th.source = .System
	}
}

theming_destroy :: proc(th: ^Theming) {
	delete(th.omarchy_name)
}

// Once per frame: pick up `omarchy theme set`, or a change in System
// Settings, while following it.
theming_update :: proc(th: ^Theming) {
	switch th.source {
	case .Omarchy:
		if omarchy.changed() {
			theming_load_omarchy(th, THEME_FADE)
		}
	case .System:
		if appearance.changed() {
			theming_load_system(th, THEME_FADE)
		}
	case .Dark, .Light:
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
	case .System:
		if !theming_load_system(th, fade) {
			return
		}
	case .Dark:
		ui.set_palette(ui.PALETTE_DARK, fade)
		appearance.match_window(ui.Theme_Mode.Dark)
	case .Light:
		ui.set_palette(ui.palette_from_base(ui.BASE_LIGHT), fade)
		appearance.match_window(ui.Theme_Mode.Light)
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

// The title bar follows the system here, so the window override is cleared.
@(private = "file")
theming_load_system :: proc(th: ^Theming, fade: f32) -> bool {
	t, ok := appearance.load()
	if !ok {
		return false
	}
	th.system = true
	th.system_name = t.name
	ui.set_palette(ui.palette_from_base(t.base), fade)
	appearance.match_window(nil)
	return true
}
