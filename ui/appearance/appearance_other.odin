#+build !darwin
package appearance

import ui ".."

load :: proc() -> (t: Theme, ok: bool) {
	return
}

changed :: proc() -> bool {
	return false
}

match_window :: proc(mode: Maybe(ui.Theme_Mode)) {}
