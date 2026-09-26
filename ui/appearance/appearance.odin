// Follow the system appearance on macOS: Light or Dark, the accent color
// picked in System Settings, and the window and text colors that go with
// them.
//
//   if t, ok := appearance.load(); ok {
//       ui.set_palette(ui.palette_from_base(t.base))
//   }
//   // each frame:
//   if appearance.changed() { ... load again ... }
//
// Optional: the ui package never imports this. On other platforms load
// reports ok = false, changed stays false, and match_window does nothing.
package appearance

import ui ".."

Theme :: struct {
	base: ui.Theme_Base,
	name: string, // "Dark" or "Light", static
}
