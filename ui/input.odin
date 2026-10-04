package ui

import clay "../deps/clay"
import rl "../deps/raylib"

// Per-frame input. Widgets read this. On macOS the mouse and key fields are
// filled from an NSEvent monitor so a press and release inside one poll still
// count.

Input :: struct {
	mouse_x, mouse_y:           f32,
	mouse_delta_x, mouse_delta_y: f32,
	wheel_x, wheel_y:           f32,
	// bit 0 = left, 1 = right, 2 = middle
	mouse_down:     u8,
	mouse_pressed:  u8,
	mouse_released: u8,
	keys_pressed:   bit_set[Key],
	keys_down:      bit_set[Key],
	// Pressed, or auto-repeated while held: for editing keys (Backspace,
	// arrows), where holding should keep going. keys_pressed never repeats.
	keys_repeat:    bit_set[Key],
	mods:           bit_set[Mod],
	// Text typed this frame, in order, as the keyboard layout produced it
	// (Shift, Option on macOS, dead keys). Control characters are left out;
	// Enter, Tab and Backspace come in as keys.
	chars:          [32]rune,
	char_count:     int,
}

Mod :: enum u8 {
	Shift,
	Ctrl,
	Alt,
	Super, // Cmd on macOS
}

input: Input

Key :: enum u16 {
	Unknown = 0,
	Escape, Enter, Space, Tab, Backspace, Delete,
	Left, Right, Up, Down,
	A, B, C, D, E, F, G, H, I, J, K, L, M,
	N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
	F1, F3,
	Home, End, Page_Up, Page_Down,
	// By the character the key types in the current layout, not its position:
	// Plus is whichever key types + or = (on a German layout, where US has ]).
	// Pressed only; not tracked in keys_down.
	Plus, Minus, Zero,
	KP_Add, KP_Subtract, KP_0,
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
	return k in input.keys_pressed
}

key_down :: proc(k: Key) -> bool {
	return k in input.keys_down
}

// Pressed this frame or auto-repeating: for keys that should keep acting
// while held.
key_repeat :: proc(k: Key) -> bool {
	return k in input.keys_repeat
}

// The text typed this frame.
typed :: proc() -> []rune {
	return input.chars[:input.char_count]
}

// The platform's command modifier: Cmd on macOS, Ctrl elsewhere.
PRIMARY_MOD :: Mod.Super when ODIN_OS == .Darwin else Mod.Ctrl

// A press with no modifiers held: a bare shortcut, not Cmd+N.
key_pressed_bare :: proc(k: Key) -> bool {
	return k in input.keys_pressed && input.mods == {}
}

point_in_box :: proc(px, py: f32, box: clay.BoundingBox) -> bool {
	return px >= box.x && px <= box.x + box.width &&
	       py >= box.y && py <= box.y + box.height
}

mouse_in_box :: proc(box: clay.BoundingBox) -> bool {
	return point_in_box(input.mouse_x, input.mouse_y, box)
}

@(private)
poll_input :: proc() {
	took_mouse, took_keys := false, false
	when ODIN_OS == .Darwin {
		took_mouse = darwin_take_mouse()
		took_keys = darwin_take_keys()
	}
	if !took_mouse {
		mp := rl.GetMousePosition()
		input.mouse_x = mp.x
		input.mouse_y = mp.y
		md := rl.GetMouseDelta()
		input.mouse_delta_x = md.x
		input.mouse_delta_y = md.y
		wheel := rl.GetMouseWheelMoveV()
		input.wheel_x = wheel.x
		input.wheel_y = wheel.y
		input.mouse_down = 0
		input.mouse_pressed = 0
		input.mouse_released = 0
		if rl.IsMouseButtonDown(.LEFT) do input.mouse_down |= 1 << u8(Mouse_Button.Left)
		if rl.IsMouseButtonDown(.RIGHT) do input.mouse_down |= 1 << u8(Mouse_Button.Right)
		if rl.IsMouseButtonDown(.MIDDLE) do input.mouse_down |= 1 << u8(Mouse_Button.Middle)
		if rl.IsMouseButtonPressed(.LEFT) do input.mouse_pressed |= 1 << u8(Mouse_Button.Left)
		if rl.IsMouseButtonPressed(.RIGHT) do input.mouse_pressed |= 1 << u8(Mouse_Button.Right)
		if rl.IsMouseButtonPressed(.MIDDLE) do input.mouse_pressed |= 1 << u8(Mouse_Button.Middle)
		if rl.IsMouseButtonReleased(.LEFT) do input.mouse_released |= 1 << u8(Mouse_Button.Left)
		if rl.IsMouseButtonReleased(.RIGHT) do input.mouse_released |= 1 << u8(Mouse_Button.Right)
		if rl.IsMouseButtonReleased(.MIDDLE) do input.mouse_released |= 1 << u8(Mouse_Button.Middle)
	}
	// Points to layout units.
	input.mouse_x /= zoom
	input.mouse_y /= zoom
	input.mouse_delta_x /= zoom
	input.mouse_delta_y /= zoom

	// Text comes from GLFW's character callback everywhere (macOS too: the
	// monitor passes key events on), which applies the layout, Option and
	// dead keys. Cmd combinations type nothing.
	input.char_count = 0
	for r := rl.GetCharPressed(); r != 0; r = rl.GetCharPressed() {
		// Control characters, and macOS's private-use function-key range.
		if r < 0x20 || r == 0x7f || (r >= 0xf700 && r <= 0xf8ff) {
			continue
		}
		if input.char_count < len(input.chars) {
			input.chars[input.char_count] = r
			input.char_count += 1
		}
	}
	if took_keys {
		return
	}

	// Raylib only compares key state between polls, so a tap that starts and
	// ends inside one poll is lost here. macOS takes keys from the monitor.
	input.keys_pressed = {}
	input.keys_down = {}
	input.keys_repeat = {}
	input.mods = {}
	if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) do input.mods += {.Shift}
	if rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) do input.mods += {.Ctrl}
	if rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT) do input.mods += {.Alt}
	if rl.IsKeyDown(.LEFT_SUPER) || rl.IsKeyDown(.RIGHT_SUPER) do input.mods += {.Super}
	poll_key(.Escape, .ESCAPE)
	poll_key(.Enter, .ENTER)
	poll_key(.Space, .SPACE)
	poll_key(.Tab, .TAB)
	poll_key(.Backspace, .BACKSPACE)
	poll_key(.Delete, .DELETE)
	poll_key(.Left, .LEFT)
	poll_key(.Right, .RIGHT)
	poll_key(.Up, .UP)
	poll_key(.Down, .DOWN)
	poll_key(.A, .A); poll_key(.B, .B); poll_key(.C, .C); poll_key(.D, .D)
	poll_key(.E, .E); poll_key(.F, .F); poll_key(.G, .G); poll_key(.H, .H)
	poll_key(.I, .I); poll_key(.J, .J); poll_key(.K, .K); poll_key(.L, .L)
	poll_key(.M, .M); poll_key(.N, .N); poll_key(.O, .O); poll_key(.P, .P)
	poll_key(.Q, .Q); poll_key(.R, .R); poll_key(.S, .S); poll_key(.T, .T)
	poll_key(.U, .U); poll_key(.V, .V); poll_key(.W, .W); poll_key(.X, .X)
	poll_key(.Y, .Y); poll_key(.Z, .Z)
	poll_key(.F1, .F1); poll_key(.F3, .F3)
	poll_key(.Home, .HOME); poll_key(.End, .END)
	poll_key(.Page_Up, .PAGE_UP); poll_key(.Page_Down, .PAGE_DOWN)
	poll_key(.KP_Add, .KP_ADD); poll_key(.KP_Subtract, .KP_SUBTRACT); poll_key(.KP_0, .KP_0)

	// raylib names keys by their US position, so on a German layout + comes
	// in as RIGHT_BRACKET and - as SLASH. Match these by what they type.
	for k := rl.GetKeyPressed(); k != .KEY_NULL; k = rl.GetKeyPressed() {
		switch string(rl.GetKeyName(k)) {
		case "+", "=":
			input.keys_pressed += {.Plus}
		case "-":
			input.keys_pressed += {.Minus}
		case "0":
			input.keys_pressed += {.Zero}
		}
	}
}

@(private)
poll_key :: proc(k: Key, rk: rl.KeyboardKey) {
	if rl.IsKeyPressed(rk) {
		input.keys_pressed += {k}
		input.keys_repeat += {k}
	} else if rl.IsKeyPressedRepeat(rk) {
		input.keys_repeat += {k}
	}
	if rl.IsKeyDown(rk) {
		input.keys_down += {k}
	}
}
