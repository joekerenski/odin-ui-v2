#+build !linux
package omarchy

load :: proc(allocator := context.allocator) -> (t: Theme, ok: bool) {
	return
}

changed :: proc() -> bool {
	return false
}
