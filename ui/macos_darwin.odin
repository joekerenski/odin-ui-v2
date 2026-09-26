package ui

// macOS extras on top of raylib/GLFW:
//   - NSEvent monitor so a click or key tap inside one poll still counts
//   - Spaces fullscreen (toggleFullScreen:) so the Retina backing scale stays
//   - the view's display link as the frame clock, with swap interval left at 0
//   - a fixed present deadline in fullscreen on adaptive-refresh screens
//
// The link (NSView.displayLink, macOS 14+) runs on its own thread and run
// loop. Its tick bumps a counter, stores the target time, and signals a
// semaphore. The main thread waits on that until the counter has moved.
//
// Fullscreen on an adaptive screen (ProMotion, adaptive-sync externals) scans
// out directly, and the panel refreshes when a frame lands. The link then
// reports those refreshes back (ticks 2-11ms apart at a 60fps cadence), so
// pacing on it follows its own echo. There the clock is a deadline grid
// instead: the thread wakes just early enough for the frame's work, the batch
// is flushed, the thread sleeps to the deadline, and the swap goes out on it.
// The thread is time-constrained while that runs, or the wake lands ~1ms late
// with jitter from timer coalescing. Without a view display link (before
// macOS 14) the deadline grid is the clock everywhere.

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:thread"
import Foundation "core:sys/darwin/Foundation"
import rl "../deps/raylib"

foreign import objc_runtime "system:objc"
foreign objc_runtime {
	@(link_name = "_NSConcreteGlobalBlock")
	_NSConcreteGlobalBlock: intrinsics.objc_class
}

foreign import libsystem "system:System"
foreign libsystem {
	@(link_name = "mach_timebase_info")
	mach_timebase_info :: proc(info: ^Mach_Timebase) -> i32 ---
	mach_absolute_time :: proc() -> u64 ---
	mach_wait_until :: proc(deadline: u64) -> i32 ---
	pthread_self :: proc() -> rawptr ---
	pthread_mach_thread_np :: proc(thread: rawptr) -> u32 ---
	thread_policy_set :: proc(thread: u32, flavor: u32, policy: rawptr, count: u32) -> i32 ---
	dispatch_semaphore_create :: proc(value: int) -> rawptr ---
	dispatch_semaphore_wait :: proc(sema: rawptr, timeout: u64) -> int ---
	dispatch_semaphore_signal :: proc(sema: rawptr) -> int ---
	dispatch_time :: proc(base: u64, delta: i64) -> u64 ---
	dispatch_release :: proc(object: rawptr) ---
}

DISPATCH_TIME_NOW :: 0

foreign import CoreFoundation "system:CoreFoundation.framework"
foreign CoreFoundation {
	CFRunLoopGetCurrent :: proc() -> rawptr ---
	CFRunLoopRun :: proc() ---
	CFRunLoopStop :: proc(loop: rawptr) ---
}

THREAD_STANDARD_POLICY :: 1
THREAD_TIME_CONSTRAINT_POLICY :: 2

Thread_Time_Constraint :: struct {
	period:      u32,
	computation: u32,
	constraint:  u32,
	preemptible: u32,
}

Mach_Timebase :: struct {
	numer: u32,
	denom: u32,
}

BLOCK_IS_GLOBAL :: 1 << 28

@(private)
Input_Monitor_Block :: struct {
	isa:        rawptr,
	flags:      c.int,
	reserved:   c.int,
	invoke:     rawptr,
	descriptor: rawptr,
}

@(private)
s_monitor_block: Input_Monitor_Block
@(private)
s_monitor_token: rawptr
@(private)
s_monitor_active: bool

@(private)
s_ev_x, s_ev_y, s_ev_dx, s_ev_dy, s_ev_wheel_x, s_ev_wheel_y: f32
@(private)
s_ev_down, s_ev_pressed, s_ev_released: u8
@(private)
s_key_down, s_key_pressed: bit_set[Key]
@(private)
s_key_mods: bit_set[Mod]

EV_LEFT_DOWN, EV_LEFT_UP :: 1, 2
EV_RIGHT_DOWN, EV_RIGHT_UP :: 3, 4
EV_MOUSE_MOVED :: 5
EV_LEFT_DRAGGED, EV_RIGHT_DRAGGED :: 6, 7
EV_KEY_DOWN, EV_KEY_UP, EV_FLAGS_CHANGED :: 10, 11, 12
EV_SCROLL_WHEEL :: 22
EV_OTHER_DOWN, EV_OTHER_UP, EV_OTHER_DRAGGED :: 25, 26, 27

@(private)
input_monitor_invoke :: proc "c" (block: rawptr, event: rawptr) -> rawptr {
	context = runtime.default_context()
	obj := cast(^Foundation.Object)event
	etype := intrinsics.objc_send(uintptr, obj, "type")
	switch etype {
	case EV_LEFT_DOWN, EV_RIGHT_DOWN, EV_OTHER_DOWN:
		btn := Mouse_Button(intrinsics.objc_send(int, obj, "buttonNumber"))
		s_ev_down |= 1 << u8(btn)
		s_ev_pressed |= 1 << u8(btn)
		mouse_pos_from_event(obj)
	case EV_LEFT_UP, EV_RIGHT_UP, EV_OTHER_UP:
		btn := Mouse_Button(intrinsics.objc_send(int, obj, "buttonNumber"))
		s_ev_down &~= 1 << u8(btn)
		s_ev_released |= 1 << u8(btn)
		mouse_pos_from_event(obj)
	case EV_MOUSE_MOVED, EV_LEFT_DRAGGED, EV_RIGHT_DRAGGED, EV_OTHER_DRAGGED:
		mouse_pos_from_event(obj)
		s_ev_dx += f32(intrinsics.objc_send(f64, obj, "deltaX"))
		s_ev_dy += f32(intrinsics.objc_send(f64, obj, "deltaY"))
	case EV_SCROLL_WHEEL:
		dx := intrinsics.objc_send(f64, obj, "scrollingDeltaX")
		dy := intrinsics.objc_send(f64, obj, "scrollingDeltaY")
		if intrinsics.objc_send(bool, obj, "hasPreciseScrollingDeltas") {
			dx *= 0.1
			dy *= 0.1
		}
		s_ev_wheel_x += f32(dx)
		s_ev_wheel_y += f32(dy)
	case EV_KEY_DOWN:
		if k := key_from_event(obj); k != .Unknown {
			s_key_down += {k}
			// Auto-repeat is not a new press, same as raylib's IsKeyPressed.
			if !intrinsics.objc_send(bool, obj, "isARepeat") {
				s_key_pressed += {k}
			}
		}
		s_key_mods = mods_from_flags(intrinsics.objc_send(uint, obj, "modifierFlags"))
	case EV_KEY_UP:
		if k := key_from_event(obj); k != .Unknown {
			s_key_down -= {k}
		}
		s_key_mods = mods_from_flags(intrinsics.objc_send(uint, obj, "modifierFlags"))
	case EV_FLAGS_CHANGED:
		s_key_mods = mods_from_flags(intrinsics.objc_send(uint, obj, "modifierFlags"))
	}
	return event
}

@(private)
mods_from_flags :: proc(flags: uint) -> (mods: bit_set[Mod]) {
	if flags & (1 << 17) != 0 do mods += {.Shift}
	if flags & (1 << 18) != 0 do mods += {.Ctrl}
	if flags & (1 << 19) != 0 do mods += {.Alt}
	if flags & (1 << 20) != 0 do mods += {.Super}
	return
}

@(private)
key_from_event :: proc(obj: ^Foundation.Object) -> Key {
	if k := key_from_code(intrinsics.objc_send(u16, obj, "keyCode")); k != .Unknown {
		return k
	}
	return key_from_chars(obj)
}

// +, - and 0 by the character they type (Shift applies, other modifiers do
// not), since their key codes are US positions: on a German layout + sits
// where US has ].
@(private)
key_from_chars :: proc(obj: ^Foundation.Object) -> Key {
	chars := intrinsics.objc_send(^Foundation.Object, obj, "charactersIgnoringModifiers")
	if chars == nil {
		return .Unknown
	}
	utf8 := intrinsics.objc_send(cstring, chars, "UTF8String")
	if utf8 == nil {
		return .Unknown
	}
	switch string(utf8) {
	case "+", "=":
		return .Plus
	case "-":
		return .Minus
	case "0":
		return .Zero
	}
	return .Unknown
}

// kVK_* virtual key codes: physical positions on an ANSI layout, as GLFW uses.
@(private)
key_from_code :: proc(code: u16) -> Key {
	switch code {
	case 0x35: return .Escape
	case 0x24, 0x4C: return .Enter
	case 0x31: return .Space
	case 0x30: return .Tab
	case 0x33: return .Backspace
	case 0x75: return .Delete
	case 0x7B: return .Left
	case 0x7C: return .Right
	case 0x7E: return .Up
	case 0x7D: return .Down
	case 0x00: return .A
	case 0x0B: return .B
	case 0x08: return .C
	case 0x02: return .D
	case 0x0E: return .E
	case 0x03: return .F
	case 0x05: return .G
	case 0x04: return .H
	case 0x22: return .I
	case 0x26: return .J
	case 0x28: return .K
	case 0x25: return .L
	case 0x2E: return .M
	case 0x2D: return .N
	case 0x1F: return .O
	case 0x23: return .P
	case 0x0C: return .Q
	case 0x0F: return .R
	case 0x01: return .S
	case 0x11: return .T
	case 0x20: return .U
	case 0x09: return .V
	case 0x0D: return .W
	case 0x07: return .X
	case 0x10: return .Y
	case 0x06: return .Z
	case 0x7A: return .F1
	case 0x63: return .F3
	case 0x45: return .KP_Add
	case 0x4E: return .KP_Subtract
	case 0x52: return .KP_0
	}
	return .Unknown
}

@(private)
mouse_pos_from_event :: proc(obj: ^Foundation.Object) {
	loc := intrinsics.objc_send(Foundation.Point, obj, "locationInWindow")
	s_ev_x = f32(loc.x)
	s_ev_y = screen_h - f32(loc.y)
}

@(private)
install_input_monitor :: proc() {
	if s_monitor_active {
		return
	}
	s_monitor_block = Input_Monitor_Block{
		isa        = &_NSConcreteGlobalBlock,
		flags      = BLOCK_IS_GLOBAL,
		invoke     = rawptr(input_monitor_invoke),
		descriptor = nil,
	}
	cls := cast(^Foundation.Object)Foundation.objc_lookUpClass("NSEvent")
	if cls == nil {
		return
	}
	mask := uintptr(
		1 << EV_LEFT_DOWN | 1 << EV_LEFT_UP | 1 << EV_RIGHT_DOWN | 1 << EV_RIGHT_UP |
		1 << EV_OTHER_DOWN | 1 << EV_OTHER_UP | 1 << EV_MOUSE_MOVED |
		1 << EV_LEFT_DRAGGED | 1 << EV_RIGHT_DRAGGED | 1 << EV_OTHER_DRAGGED |
		1 << EV_SCROLL_WHEEL | 1 << EV_KEY_DOWN | 1 << EV_KEY_UP | 1 << EV_FLAGS_CHANGED)
	s_monitor_token = intrinsics.objc_send(rawptr, cls, "addLocalMonitorForEventsMatchingMask:handler:", mask, &s_monitor_block)
	s_monitor_active = s_monitor_token != nil
}

@(private)
shutdown_input_monitor :: proc() {
	if !s_monitor_active {
		return
	}
	cls := cast(^Foundation.Object)Foundation.objc_lookUpClass("NSEvent")
	intrinsics.objc_send(nil, cls, "removeMonitor:", s_monitor_token)
	s_monitor_active = false
	s_monitor_token = nil
}

// Copy the monitor's edges into `input` and clear the one-frame fields.
// Returns false when the monitor is not installed.
darwin_take_mouse :: proc() -> bool {
	if !s_monitor_active {
		return false
	}
	input.mouse_x = s_ev_x
	input.mouse_y = s_ev_y
	input.mouse_delta_x = s_ev_dx
	input.mouse_delta_y = s_ev_dy
	input.wheel_x = s_ev_wheel_x
	input.wheel_y = s_ev_wheel_y
	input.mouse_down = s_ev_down
	input.mouse_pressed = s_ev_pressed
	input.mouse_released = s_ev_released
	s_ev_dx, s_ev_dy = 0, 0
	s_ev_wheel_x, s_ev_wheel_y = 0, 0
	s_ev_pressed, s_ev_released = 0, 0
	return true
}

// Same for keys. A key released while the window was not key never sends its
// key-up here, so held state is dropped whenever the window loses focus.
darwin_take_keys :: proc() -> bool {
	if !s_monitor_active {
		return false
	}
	win := cast(^Foundation.Object)rl.GetWindowHandle()
	if win != nil && !intrinsics.objc_send(bool, win, "isKeyWindow") {
		s_key_down = {}
		s_key_mods = {}
	}
	input.keys_pressed = s_key_pressed
	input.keys_down = s_key_down
	input.mods = s_key_mods
	s_key_pressed = {}
	return true
}

darwin_toggle_fullscreen :: proc() {
	win := cast(^Foundation.Window)rl.GetWindowHandle()
	if win == nil {
		return
	}
	Foundation.Window_toggleFullScreen(win, nil)
}

darwin_is_fullscreen :: proc() -> bool {
	win := cast(^Foundation.Window)rl.GetWindowHandle()
	if win == nil {
		return false
	}
	mask := intrinsics.objc_send(Foundation.WindowStyleMask, win, "styleMask")
	return Foundation.WindowStyleFlag.FullScreen in mask
}

// --- display link -----------------------------------------------------------

@(private)
link_obj: ^Foundation.Object
@(private)
link_thread: ^thread.Thread
@(private)
link_loop: rawptr
@(private)
link_ready: rawptr
@(private)
link_sem: rawptr
@(private)
link_gen: i64
@(private)
link_target: u64 // f64 bits: targetTimestamp of the latest tick, host seconds
@(private)
link_period: u64 // f64 bits: targetTimestamp - timestamp
@(private)
link_screen: ^Foundation.Screen
@(private)
pace_mark: i64
@(private)
pace_started: bool
@(private)
last_target: f64
@(private)
timebase: Mach_Timebase
@(private)
screen_adaptive: bool
@(private)
screen_min_interval: f64
@(private)
deadline_mode: bool
@(private)
present_at: u64
@(private)
work_peak: f64

@(private)
link_tick :: proc "c" (self: rawptr, cmd: rawptr, link: ^Foundation.Object) {
	ts := intrinsics.objc_send(f64, link, "timestamp")
	target := intrinsics.objc_send(f64, link, "targetTimestamp")
	intrinsics.atomic_store(&link_target, transmute(u64)target)
	intrinsics.atomic_store(&link_period, transmute(u64)(target - ts))
	intrinsics.atomic_add(&link_gen, 1)
	dispatch_semaphore_signal(link_sem)
}

// Adds the link to this thread's run loop and runs it until darwin_stop.
@(private)
link_thread_proc :: proc() {
	Foundation.scoped_autoreleasepool()
	cls := cast(^Foundation.Object)Foundation.objc_lookUpClass("NSRunLoop")
	loop := intrinsics.objc_send(^Foundation.Object, cls, "currentRunLoop")
	intrinsics.objc_send(nil, link_obj, "addToRunLoop:forMode:", loop, Foundation.RunLoopCommonModes)
	link_loop = CFRunLoopGetCurrent()
	dispatch_semaphore_signal(link_ready)
	CFRunLoopRun()
	intrinsics.objc_send(nil, link_obj, "invalidate")
}

@(private)
link_target_class :: proc() -> Foundation.Class {
	name :: "UIFrameLinkTarget"
	if cls := Foundation.objc_lookUpClass(name); cls != nil {
		return cls
	}
	cls := Foundation.objc_allocateClassPair(intrinsics.objc_find_class("NSObject"), name, 0)
	if cls == nil {
		return nil
	}
	Foundation.class_addMethod(cls, intrinsics.objc_find_selector("tick:"), auto_cast link_tick, "v@:@")
	Foundation.objc_registerClassPair(cls)
	return cls
}

// The view's link follows the window between screens on its own.
@(private)
start_link :: proc() {
	win := cast(^Foundation.Window)rl.GetWindowHandle()
	if win == nil {
		return
	}
	view := intrinsics.objc_send(^Foundation.Object, win, "contentView")
	sel := intrinsics.objc_find_selector("displayLinkWithTarget:selector:")
	if view == nil || !intrinsics.objc_send(bool, view, "respondsToSelector:", sel) {
		return
	}
	cls := link_target_class()
	if cls == nil {
		return
	}
	target := intrinsics.objc_send(^Foundation.Object, intrinsics.objc_send(^Foundation.Object, cast(^Foundation.Object)cls, "alloc"), "init")
	link := intrinsics.objc_send(^Foundation.Object, view, "displayLinkWithTarget:selector:", target, intrinsics.objc_find_selector("tick:"))
	intrinsics.objc_send(nil, target, "release") // the link holds it
	if link == nil {
		return
	}
	link_obj = intrinsics.objc_send(^Foundation.Object, link, "retain")
	link_sem = dispatch_semaphore_create(0)
	link_ready = dispatch_semaphore_create(0)
	link_thread = thread.create_and_start(link_thread_proc, name = "frame link")
	dispatch_semaphore_wait(link_ready, ~u64(0))
}

@(private)
stop_link :: proc() {
	if link_obj == nil {
		return
	}
	CFRunLoopStop(link_loop)
	thread.join(link_thread)
	thread.destroy(link_thread)
	intrinsics.objc_send(nil, link_obj, "release")
	dispatch_release(link_sem)
	dispatch_release(link_ready)
	link_obj, link_thread, link_loop, link_sem, link_ready = nil, nil, nil, nil, nil
}

// minimumRefreshInterval < maximumRefreshInterval means the panel can hold a
// frame for longer than one refresh: ProMotion, or adaptive sync. macOS 12+.
// Re-read whenever the window lands on another screen.
@(private)
read_screen_refresh :: proc() {
	win := cast(^Foundation.Window)rl.GetWindowHandle()
	if win == nil {
		return
	}
	screen := Foundation.Window_screen(win)
	if screen == link_screen {
		return
	}
	link_screen = screen
	screen_adaptive = false
	screen_min_interval = 0
	if screen == nil || !intrinsics.objc_send(bool, screen, "respondsToSelector:", intrinsics.objc_find_selector("maximumRefreshInterval")) {
		return
	}
	lo := intrinsics.objc_send(f64, screen, "minimumRefreshInterval")
	hi := intrinsics.objc_send(f64, screen, "maximumRefreshInterval")
	screen_min_interval = lo
	screen_adaptive = lo > 0 && hi > lo * 1.5
}

darwin_start :: proc() {
	install_input_monitor()
	mach_timebase_info(&timebase)
	read_screen_refresh()
	start_link()
}

darwin_stop :: proc() {
	shutdown_input_monitor()
	set_realtime(false)
	stop_link()
}

@(private)
host_seconds :: proc(delta: u64) -> f64 {
	if timebase.denom == 0 {
		return 0
	}
	return f64(delta) * f64(timebase.numer) / f64(timebase.denom) / 1e9
}

@(private)
seconds_to_host :: proc(s: f64) -> u64 {
	if timebase.numer == 0 {
		return 0
	}
	return u64(s * 1e9 * f64(timebase.denom) / f64(timebase.numer))
}

// Link ticks per frame: 1 when following the display, 2 for 60 on 120 Hz.
@(private)
vblank_step :: proc() -> i64 {
	period := transmute(f64)intrinsics.atomic_load(&link_period)
	if period <= 0 || target_fps <= 0 {
		return 1
	}
	return max(i64(1.0 / period / f64(target_fps) + 0.5), 1)
}

// One frame on the deadline grid: the target rate, or the panel's fastest.
@(private)
deadline_period :: proc() -> u64 {
	s := screen_min_interval
	if target_fps > 0 && 1.0 / f64(target_fps) > s {
		s = 1.0 / f64(target_fps)
	}
	if s <= 0 {
		s = 1.0 / 60.0
	}
	return seconds_to_host(s)
}

// Time-constrained scheduling: wakes on the deadline instead of ~1ms after
// it. The budget is half a period; a frame that runs longer gets demoted by
// the kernel for a while, which only costs precision.
@(private)
set_realtime :: proc(on: bool) {
	thread := pthread_mach_thread_np(pthread_self())
	if on {
		period := deadline_period()
		policy := Thread_Time_Constraint{
			period      = u32(period),
			computation = u32(period / 2),
			constraint  = u32(period),
			preemptible = 1,
		}
		thread_policy_set(thread, THREAD_TIME_CONSTRAINT_POLICY, &policy, 4)
	} else {
		none: u32
		thread_policy_set(thread, THREAD_STANDARD_POLICY, &none, 0)
	}
}

// Wait for this frame's slot to open; the caller polls input right after.
//
// Link mode (windowed, or a fixed-rate screen): block until `vblank_step`
// ticks have landed since the last frame. A 100ms cap keeps a dead link from
// freezing quit. After the wait the mark jumps to the current counter, so a
// hitch does not replay stale ticks.
//
// Deadline mode: pick the next slot and sleep until the frame's recent peak
// work time before it. `darwin_present_wait` holds the swap for the slot.
darwin_pace :: proc() {
	read_screen_refresh()
	use_deadline := link_obj == nil || (screen_adaptive && darwin_is_fullscreen())
	if use_deadline != deadline_mode {
		deadline_mode = use_deadline
		set_realtime(use_deadline)
		present_at = 0
		pace_started = false
	}
	work_peak = max(f64(busy_dt), work_peak * 0.99)

	if deadline_mode {
		period := deadline_period()
		now := mach_absolute_time()
		if present_at == 0 {
			present_at = now
		}
		prev := present_at
		present_at += period
		lead := clamp(seconds_to_host(work_peak * 1.5 + 0.001), seconds_to_host(0.002), period * 3 / 4)
		if present_at - lead > now {
			mach_wait_until(present_at - lead)
		}
		frame_dt = f32(host_seconds(present_at - prev))
		return
	}

	if !pace_started {
		pace_started = true
		for dispatch_semaphore_wait(link_sem, DISPATCH_TIME_NOW) == 0 {} // drop ticks from deadline mode
		pace_mark = intrinsics.atomic_load(&link_gen)
		last_target = transmute(f64)intrinsics.atomic_load(&link_target)
		frame_dt = 1.0 / 60.0
		return
	}

	target := pace_mark + vblank_step()
	limit := dispatch_time(DISPATCH_TIME_NOW, 100_000_000)
	for intrinsics.atomic_load(&link_gen) < target && !quit_requested {
		if dispatch_semaphore_wait(link_sem, limit) != 0 {
			break
		}
	}
	pace_mark = intrinsics.atomic_load(&link_gen)

	t := transmute(f64)intrinsics.atomic_load(&link_target)
	if last_target > 0 && t > last_target && t - last_target < 0.5 {
		frame_dt = f32(t - last_target)
	}
	last_target = t
}

// Deadline mode only: sleep until this frame's slot so the swap leaves on it.
// Call after the batch is flushed. A frame that missed its slot presents now
// and the grid restarts from there.
darwin_present_wait :: proc() {
	if !deadline_mode {
		return
	}
	now := mach_absolute_time()
	if now < present_at {
		mach_wait_until(present_at)
	} else {
		present_at = now
	}
}
