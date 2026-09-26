// Follow the active Omarchy theme (https://omarchy.org), on Linux.
//
//   if t, ok := omarchy.load(); ok {
//       ui.set_palette(ui.palette_from_base(t.base))
//   }
//   // each frame:
//   if omarchy.changed() { ... load again ... }
//
// Optional: the ui package never imports this. On other platforms, and on
// Linux without Omarchy, load reports ok = false and changed stays false.
package omarchy

import ui ".."

Theme :: struct {
	base: ui.Theme_Base,
	name: string, // "Everforest", as `omarchy theme current` prints it
}
