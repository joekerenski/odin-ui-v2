package ui

import clay "../deps/clay"
import "core:math"

// Animated values for immediate-mode widgets. A widget has no object to keep
// state in, so each value lives in a table keyed by the widget's id and a
// channel, and eases toward whatever target the widget asks for this frame:
//
//   k := ui.anim(id, 1 if hot else 0, ui.theme.motion.hover)
//   bg := ui.mix(rest, hover, k)
//
// A value is a spring, not a timed tween. Retargeted mid-flight (the pointer
// sweeping across a row of buttons) it turns around from where it is, with
// its speed, instead of restarting or jumping. `duration` is about how long
// it takes to settle; `bounce` above 0 overshoots, for things that move (not
// colors, which would overshoot past their target). A value no widget asks
// for during a frame is dropped, so a widget that comes back starts at rest
// on its target, or at `from`.

@(private)
Anim :: struct {
	value:    f32,
	velocity: f32,
	seen:     u64,
}

@(private)
s_anims: map[u64]Anim

// Frames since init; stamps what was asked for when.
@(private)
s_frame: u64

anim :: proc(id: string, target: f32, duration: f32, bounce: f32 = 0, channel: u32 = 0, from: Maybe(f32) = nil) -> f32 {
	key := u64(clay.ID(id).id) << 32 | u64(channel)
	a, found := s_anims[key]
	if !found {
		a.value = from.? or_else target
	}
	// Asked twice in one frame: step once.
	if a.seen != s_frame {
		a.seen = s_frame
		spring_step(&a.value, &a.velocity, target, duration, bounce, frame_dt)
	}
	s_anims[key] = a
	return a.value
}

// One frame of a damped spring toward `target`. The natural frequency makes
// a critically damped spring settle (to about 1%) in `duration`; `bounce`
// lowers the damping. Integrated in steps short against both the frame and
// the spring (omega*h <= 0.5), so a long frame or a stiff spring stays
// stable. NaN durations or values snap to the target instead of sticking.
spring_step :: proc(x, v: ^f32, target, duration, bounce, dt: f32) {
	if !(duration > 0.001) || !(dt > 0) || !finite(x^) || !finite(v^) {
		x^, v^ = target, 0
		return
	}
	dt := min(dt, 0.25) // after a stall, don't step for seconds
	omega := 2 * math.PI / duration
	zeta := 1 - math.clamp(bounce, 0, 0.95)
	steps := max(1, int(math.ceil(dt * max(240, 2 * omega))))
	h := dt / f32(steps)
	for _ in 0 ..< steps {
		acc := -omega * omega * (x^ - target) - 2 * zeta * omega * v^
		v^ += acc * h
		x^ += v^ * h
	}
	if math.abs(x^ - target) < 1e-4 && math.abs(v^) < 1e-3 {
		x^, v^ = target, 0
	}
}

@(private)
finite :: proc(f: f32) -> bool {
	return !math.is_nan(f) && !math.is_inf(f)
}

// Called by `frame`: a new frame stamp, and values nobody asked for during
// the last frame are dropped.
@(private)
anim_tick :: proc() {
	s_frame += 1
	stale := make([dynamic]u64, context.temp_allocator)
	for key, a in s_anims {
		if a.seen + 1 < s_frame {
			append(&stale, key)
		}
	}
	for key in stale {
		delete_key(&s_anims, key)
	}
	scroll_tick()
	picker_tick()
	edit_tick()
}

@(private)
anim_teardown :: proc() {
	delete(s_anims)
	s_anims = nil
	delete(s_scrolls)
	s_scrolls = nil
	delete(s_pickers)
	s_pickers = nil
}

// --- smooth scrolling ------------------------------------------------------------
//
// Clay moves a scroll container by the whole wheel step at once. Here Clay's
// result is the target, and the container eases toward it. Each frame the
// container is put back on its target before Clay applies the wheel, so steps
// add up from where the scroll is headed, not from where it happens to be.

@(private)
Scroll :: struct {
	id:       clay.ElementId,
	target:   f32,
	velocity: f32,
	seen:     u64,
}

@(private)
s_scrolls: map[u32]Scroll

// A scroll container that eases. scroll_begin and panel_begin call this.
@(private)
scroll_track :: proc(id: string) {
	eid := clay.ID(id)
	eid.stringId = {} // the string may live in the temp allocator
	s, found := s_scrolls[eid.id]
	if !found {
		s.id = eid
		data := clay.GetScrollContainerData(eid)
		if data.found {
			s.target = data.scrollPosition.y
		}
	}
	s.seen = s_frame
	s_scrolls[eid.id] = s
}

// Set a container's scroll at once, no easing (the scrollbar drag).
@(private)
scroll_jump :: proc(id: string, y: f32) {
	eid := clay.ID(id)
	data := clay.GetScrollContainerData(eid)
	if !data.found {
		return
	}
	data.scrollPosition.y = y
	if s, ok := &s_scrolls[eid.id]; ok {
		s.target = y
		s.velocity = 0
	}
}

// Ease scroll container `id` so `y` points from the top of its content
// are above the view (clamped to the content). Takes effect next frame.
scroll_to :: proc(id: string, y: f32) {
	if s, ok := &s_scrolls[clay.ID(id).id]; ok {
		s.target = -max(0, y)
	}
}

// Ease to the bottom of the content; called every frame while content grows
// (a streaming reply), it keeps the view pinned there.
scroll_to_end :: proc(id: string) {
	if s, ok := &s_scrolls[clay.ID(id).id]; ok {
		s.target = -1e9 // clamped to the content's end next frame
	}
}

// Move what container `id` shows by `dy` at once, easing in progress kept: when
// rows above the view grow or shrink (a list that lays out only what's visible,
// measuring rows as they come into view), the reader stays where they were.
scroll_shift :: proc(id: string, dy: f32) {
	eid := clay.ID(id)
	data := clay.GetScrollContainerData(eid)
	if !data.found || dy == 0 {
		return
	}
	data.scrollPosition.y += dy
	if s, ok := &s_scrolls[eid.id]; ok {
		s.target += dy
	}
}

// Put the bottom of the content in view at once, no easing (opening a log at
// its end).
scroll_end_now :: proc(id: string) {
	data := clay.GetScrollContainerData(clay.ID(id))
	if !data.found {
		return
	}
	scroll_jump(id, -max(0, data.contentDimensions.height - data.scrollContainerDimensions.height))
}

// Whether container `id` is scrolled (or headed) to within `slack` points
// of its end, or its content fits: the reader is following along.
scroll_at_end :: proc(id: string, slack: f32 = 4) -> bool {
	data := clay.GetScrollContainerData(clay.ID(id))
	if !data.found {
		return true
	}
	end := max(0, data.contentDimensions.height - data.scrollContainerDimensions.height)
	y := -data.scrollPosition.y
	if s, ok := s_scrolls[clay.ID(id).id]; ok {
		y = -s.target
	}
	return y >= end - slack
}

@(private)
scroll_tick :: proc() {
	stale := make([dynamic]u32, context.temp_allocator)
	for key, s in s_scrolls {
		if s.seen + 1 < s_frame {
			append(&stale, key)
		}
	}
	for key in stale {
		delete_key(&s_scrolls, key)
	}
}

// begin_layout wraps Clay's wheel handling in these two.
@(private)
scroll_before_wheel :: proc() -> (restore: [dynamic]f32) {
	restore = make([dynamic]f32, context.temp_allocator)
	for _, s in s_scrolls {
		data := clay.GetScrollContainerData(s.id)
		if data.found {
			append(&restore, data.scrollPosition.y)
			data.scrollPosition.y = s.target
		} else {
			append(&restore, 0)
		}
	}
	return
}

@(private)
scroll_after_wheel :: proc(restore: [dynamic]f32) {
	i := 0
	for _, &s in s_scrolls {
		defer i += 1
		data := clay.GetScrollContainerData(s.id)
		if !data.found || i >= len(restore) {
			continue
		}
		max_scroll := max(0, data.contentDimensions.height - data.scrollContainerDimensions.height)
		s.target = math.clamp(data.scrollPosition.y, -max_scroll, 0)
		y := restore[i]
		spring_step(&y, &s.velocity, s.target, theme.motion.scroll, 0, frame_dt)
		data.scrollPosition.y = math.clamp(y, -max_scroll, 0)
	}
}
