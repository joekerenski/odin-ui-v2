package ui

import clay "../deps/clay"
import "core:fmt"
import "core:math"
import "core:os"
import "core:time"

// Idle: with Window_Desc.idle_after > 0, `frame` stops returning while nothing on screen would
// change, so the app neither lays out nor draws, and the last frame stays up. The GPU rests;
// the loop still wakes each display tick to look at input, which costs next to nothing.
//
// A frame is drawn when:
//   - there is input (a button or key goes down or up, a key is held, text is typed, the
//     wheel turns) or the window changes size,
//   - the pointer moves onto another element or into or out of a hover zone (a link inside a
//     paragraph): moving within the same thing draws nothing,
//   - something is moving: a spring (`anim`), a scroll easing to its target, a theme fade,
//   - within idle_after seconds of the last of those (Clay's transitions, which can't be
//     asked, finish in that time),
//   - the app asked: `request_redraw` for the next frame (text streaming in), `wake_at` for a
//     later time (the caret's next blink, a pulse at a modest rate),
//   - and at least every IDLE_HEARTBEAT, for anything polled by time.
//
// Drawing outside Clay (raylib calls, shaders) follows the same rule: a still picture needs
// nothing, since the last frame stays up; anything that moves on its own asks for its frames,
// with request_redraw (every frame) or wake_at (a lower rate).
//
// UI_IDLE_DEBUG=1 in the environment prints, every two seconds, how many ticks drew and why.
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

// What the pointer was over when the last frame was drawn: Clay's elements and the hover zone.
@(private)
s_hover_ids: u64

@(private)
s_hover_zone: int

// Rectangles inside elements whose hover matters (links in a paragraph), this frame's.
@(private)
s_zones: [dynamic]clay.BoundingBox

// Draw the next frame even if nothing else would. Call it each frame while something the
// screen shows changes every frame (text streaming in, a canvas animating).
request_redraw :: proc() {
	s_redraw = true
}

// Draw a frame at `at` (or sooner): a blink, or an animation at a lower rate than the display's.
wake_at :: proc(at: time.Tick) {
	if w, ok := s_wake.?; !ok || time.tick_diff(at, w) > 0 {
		s_wake = at
	}
}

// Draw a frame `seconds` from now (or sooner).
wake_in :: proc(seconds: f64) {
	wake_at(time.tick_add(time.tick_now(), time.Duration(seconds * f64(time.Second))))
}

// A rectangle (layout units) inside an element whose hover changes what's drawn, so the
// pointer crossing its edge draws a frame; for widgets with parts of their own (links in rich
// text). Declared each frame, while building the UI.
hover_zone :: proc(r: clay.BoundingBox) {
	append(&s_zones, r)
}

// Whether the last tick drew nothing (the app is idle). For a frame-rate readout.
idling :: proc() -> bool {
	return s_idle_skipped
}

// Called from begin_layout, after the pointer state is set: what the pointer is over in the
// frame being drawn, and the zones start over.
@(private)
idle_begin_frame :: proc() {
	s_hover_ids = pointer_over_hash()
	s_hover_zone = zone_at(input.mouse_x, input.mouse_y)
	clear(&s_zones)
}

@(private)
idle_teardown :: proc() {
	delete(s_zones)
	s_zones = nil
}

@(private = "file")
Idle_Stats :: struct {
	ticks, drawn, input, hover, moving, redraw, wake, heartbeat, grace: int,
	since:                                                             time.Tick,
}

@(private = "file")
s_stats: Idle_Stats

@(private = "file")
s_debug: Maybe(bool)

// After a tick's input is polled: true to skip drawing this tick.
@(private)
idle_skip :: proc() -> bool {
	if s_idle_after <= 0 { return false }
	now := time.tick_now()
	size := [2]f32{screen_w, screen_h}
	reason := ""
	switch {
	case input_active():           reason = "input"
	case size != s_idle_size:      reason = "input"
	case hover_changed():          reason = "hover"
	case moving():                 reason = "moving"
	case s_redraw:                 reason = "redraw"
	}
	if reason != "" {
		s_redraw = false
		s_idle_size = size
		// The pointer's hover is a single frame, not a burst: moving across a list draws one
		// frame per element entered, not idle_after seconds of them.
		if reason != "hover" { s_last_active = now }
	}
	draw := reason != ""
	if !draw && time.duration_seconds(time.tick_diff(s_last_active, now)) < f64(s_idle_after) {
		draw, reason = true, "grace"
	}
	if w, ok := s_wake.?; ok && time.tick_diff(w, now) >= 0 {
		s_wake = nil
		if !draw { draw, reason = true, "wake" }
	}
	if !draw && time.duration_seconds(time.tick_diff(s_last_drawn, now)) >= IDLE_HEARTBEAT {
		draw, reason = true, "heartbeat"
	}
	if draw {
		s_last_drawn = now
	}
	s_idle_skipped = !draw
	idle_debug(draw, reason, now)
	return !draw
}

// Input this tick that the UI could answer. The pointer moving isn't, by itself (see
// hover_changed); dragging is (a button is down).
@(private = "file")
input_active :: proc() -> bool {
	return input.wheel_x != 0 || input.wheel_y != 0 ||
		input.mouse_down != 0 || input.mouse_pressed != 0 || input.mouse_released != 0 ||
		input.keys_pressed != {} || input.keys_down != {} || input.keys_repeat != {} ||
		input.char_count > 0
}

// The pointer moved onto another element, or across a hover zone's edge, since the last drawn
// frame. Clay answers what's under the pointer from the last layout, without a new one.
@(private = "file")
hover_changed :: proc() -> bool {
	if input.mouse_delta_x == 0 && input.mouse_delta_y == 0 { return false }
	clay.SetPointerState({input.mouse_x, input.mouse_y}, false)
	return pointer_over_hash() != s_hover_ids || zone_at(input.mouse_x, input.mouse_y) != s_hover_zone
}

@(private = "file")
pointer_over_hash :: proc() -> u64 {
	ids := clay.GetPointerOverIds()
	h: u64 = 1469598103934665603
	for k in 0 ..< ids.length {
		h = (h ~ u64(ids.internalArray[k].id)) * 1099511628211
	}
	return h
}

@(private = "file")
zone_at :: proc(x, y: f32) -> int {
	for z, k in s_zones {
		if x >= z.x && x < z.x + z.width && y >= z.y && y < z.y + z.height { return k }
	}
	return -1
}

// A spring, scroll or theme fade still on its way.
@(private = "file")
moving :: proc() -> bool {
	if s_fade.active { return true }
	for _, a in s_anims {
		if math.abs(a.velocity) > 1e-3 && a.seen + 2 >= s_frame { return true }
	}
	for _, s in s_scrolls {
		if math.abs(s.velocity) > 0.01 { return true }
	}
	return false
}

@(private = "file")
idle_debug :: proc(draw: bool, reason: string, now: time.Tick) {
	if s_debug == nil { s_debug = os.get_env("UI_IDLE_DEBUG", context.temp_allocator) != "" }
	if !s_debug.? { return }
	st := &s_stats
	if st.since == {} { st.since = now }
	st.ticks += 1
	if draw {
		st.drawn += 1
		switch reason {
		case "input":     st.input += 1
		case "hover":     st.hover += 1
		case "moving":    st.moving += 1
		case "redraw":    st.redraw += 1
		case "wake":      st.wake += 1
		case "heartbeat": st.heartbeat += 1
		case "grace":     st.grace += 1
		}
	}
	if time.duration_seconds(time.tick_diff(st.since, now)) >= 2 {
		fmt.eprintfln("ui idle: %d of %d ticks drawn (input %d, hover %d, moving %d, redraw %d, wake %d, grace %d, heartbeat %d)",
			st.drawn, st.ticks, st.input, st.hover, st.moving, st.redraw, st.wake, st.grace, st.heartbeat)
		st^ = {since = now}
	}
}
