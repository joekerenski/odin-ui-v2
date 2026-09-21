package ui

import clay "../deps/clay"

// Per-frame input. Widgets read this. On macOS the mouse fields are filled
// from an NSEvent monitor so a press and release inside one poll still count.

Input :: struct {
	mouse_x, mouse_y:           f32,
	mouse_delta_x, mouse_delta_y: f32,
	wheel_x, wheel_y:           f32,
	// bit 0 = left, 1 = right, 2 = middle
	mouse_down:     u8,
	mouse_pressed:  u8,
	mouse_released: u8,
	keys_pressed:   map[Key]bool,
	keys_down:      map[Key]bool,
}

input: Input

Key :: enum u16 {
	Unknown = 0,
	Escape, Enter, Space, Tab, Backspace, Delete,
	Left, Right, Up, Down,
	A, B, C, D, E, F, G, H, I, J, K, L, M,
	N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
	F1, F3,
}

Mouse_Button :: enum u8 {
	Left   = 0,
	Right  = 1,
	Middle = 2,
}

mouse_down :: proc(b: Mouse_Button = .Left) -> bool {
	return (input.mouse_down & (1 << u8(b))) != 0
}

mouse_pressed :: proc(b: Mouse_Button = .Left) -> bool {
	return (input.mouse_pressed & (1 << u8(b))) != 0
}

mouse_released :: proc(b: Mouse_Button = .Left) -> bool {
	return (input.mouse_released & (1 << u8(b))) != 0
}

key_pressed :: proc(k: Key) -> bool {
	return k in input.keys_pressed && input.keys_pressed[k]
}

key_down :: proc(k: Key) -> bool {
	return k in input.keys_down && input.keys_down[k]
}

point_in_box :: proc(px, py: f32, box: clay.BoundingBox) -> bool {
	return px >= box.x && px <= box.x + box.width &&
	       py >= box.y && py <= box.y + box.height
}

mouse_in_box :: proc(box: clay.BoundingBox) -> bool {
	return point_in_box(input.mouse_x, input.mouse_y, box)
}
