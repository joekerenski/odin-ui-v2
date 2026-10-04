package ui

import "core:math"
import "core:time"

// Idle: with Window_Desc.idle_after > 0, `frame` stops returning while nothing on screen would
// change, so the app neither lays out nor draws, and the last frame stays up. The GPU rests;
// the loop still wakes each display tick to look at input, which costs next to nothing.
//
// A frame is drawn when:
//   - there is input (the pointer moves, a button or key goes down or up, a key is held, text
//     is typed, the wheel turns) or the window changes size,
//   - something is moving: a spring (`anim`), a scroll easing to its target, a theme fade,
//   - within idle_after seconds of the last of those (Clay's transitions, which can't be
//     asked, finish in that time),
//   - the app asked (`request_redraw`, each frame while it has work under way: a reply
//     streaming, a job running) or a time arrives that it or a widget asked for (`wake_at`:
//     the caret's next blink),
//   - and at least every IDLE_HEARTBEAT, for anything polled by time.
//
// Without idle_after, every tick draws, as before.

IDLE_HEARTBEAT :: 1.0 // seconds

@(private)
s_idle_after: f32

@(private)
s_last_active: time.Tick

@(private)
s_last_drawn: time.Tick

@(private)
s_redraw: bool

@(private)
s_wake: Maybe(time.Tick)

@(private)
s_idle_size: [2]f32

@(private)
s_idle_skipped: bool // the last tick drew nothing

// Draw the next frame even if nothing else would. Call it each frame while work the screen
// shows is under way (a reply streaming in, a background job), so idle never freezes it.
request_redraw :: proc() {
	s_redraw = true
}

// Draw a frame at `at` (or sooner).
wake_at :: proc(at: time.Tick) {
	if w, ok := s_wake.?; !ok || time.tick_diff(at, w) > 0 {
		s_wake = at
	}
}

// Whether the last tick drew nothing (the app is idle). For a frame-rate readout.
idling :: proc() -> bool {
	return s_idle_skipped
}

// After a tick's input is polled: true to skip drawing this tick.
@(private)
idle_skip :: proc() -> bool {
	if s_idle_after <= 0 { return false }
	now := time.tick_now()
	size := [2]f32{screen_w, screen_h}
	if s_redraw || input_active() || moving() || size != s_idle_size {
		s_redraw = false
		s_idle_size = size
		s_last_active = now
	}
	draw := time.duration_seconds(time.tick_diff(s_last_active, now)) < f64(s_idle_after) ||
		time.duration_seconds(time.tick_diff(s_last_drawn, now)) >= IDLE_HEARTBEAT
	if w, ok := s_wake.?; ok && time.tick_diff(w, now) >= 0 {
		s_wake = nil
		draw = true
	}
	if draw {
		s_last_drawn = now
	}
	s_idle_skipped = !draw
	return !draw
}

// Input this tick that the UI could answer.
@(private = "file")
input_active :: proc() -> bool {
	return input.mouse_delta_x != 0 || input.mouse_delta_y != 0 ||
		input.wheel_x != 0 || input.wheel_y != 0 ||
		input.mouse_down != 0 || input.mouse_pressed != 0 || input.mouse_released != 0 ||
		input.keys_pressed != {} || input.keys_down != {} || input.keys_repeat != {} ||
		input.char_count > 0
}

// A spring, scroll or theme fade still on its way.
@(private = "file")
moving :: proc() -> bool {
	if s_fade.active { return true }
	for _, a in s_anims {
		if a.velocity != 0 && a.seen + 2 >= s_frame { return true }
	}
	for _, s in s_scrolls {
		if math.abs(s.velocity) > 0.01 { return true }
	}
	return false
}
