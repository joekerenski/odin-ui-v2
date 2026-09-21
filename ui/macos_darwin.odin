package ui

// macOS extras on top of raylib/GLFW:
//   - NSEvent monitor so a tap that lands inside one poll is still a click
//   - Spaces fullscreen (toggleFullScreen:) so the Retina backing scale stays
//   - CVDisplayLink as the frame clock, with swap interval left at 0
//
// The link callback only bumps a counter and stores the host time. The main
// thread waits until the counter has moved since the previous frame. If
// fullscreen present already blocked through a vblank, the counter has moved
// and the wait returns immediately.

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:time"
import Foundation "core:sys/darwin/Foundation"
import rl "vendor:raylib"

foreign import objc_runtime "system:objc"
foreign objc_runtime {
	@(link_name = "_NSConcreteGlobalBlock")
	_NSConcreteGlobalBlock: intrinsics.objc_class
}

foreign import libsystem "system:System"
foreign libsystem {
	@(link_name = "mach_timebase_info")
	mach_timebase_info :: proc(info: ^Mach_Timebase) -> i32 ---
}

Mach_Timebase :: struct {
	numer: u32,
	denom: u32,
}

CV_SMPTE_Time :: struct {
	subframes:        i16,
	subframeDivisor:  i16,
	counter:          u32,
	type:             u32,
	flags:            u32,
	hours:            i16,
	minutes:          i16,
	seconds:          i16,
	frames:           i16,
}

CV_Time_Stamp :: struct {
	version:            u32,
	videoTimeScale:     i32,
	videoTime:          i64,
	hostTime:           u64,
	rateScalar:         f64,
	videoRefreshPeriod: i64,
	smpteTime:          CV_SMPTE_Time,
	flags:              u64,
	reserved:           u64,
}

Link_Callback :: proc "c" (
	link: rawptr,
	now: rawptr,
	out_time: ^CV_Time_Stamp,
	flags_in: u64,
	flags_out: ^u64,
	user: rawptr,
) -> i32

foreign import CoreVideo "system:CoreVideo.framework"
foreign CoreVideo {
	CVDisplayLinkCreateWithActiveCGDisplays :: proc(out: ^rawptr) -> i32 ---
	CVDisplayLinkSetOutputCallback :: proc(link: rawptr, cb: Link_Callback, user: rawptr) -> i32 ---
	CVDisplayLinkSetCurrentCGDisplay :: proc(link: rawptr, display_id: u32) -> i32 ---
	CVDisplayLinkStart :: proc(link: rawptr) -> i32 ---
	CVDisplayLinkStop :: proc(link: rawptr) -> i32 ---
	CVDisplayLinkRelease :: proc(link: rawptr) ---
	CVDisplayLinkGetActualOutputVideoRefreshPeriod :: proc(link: rawptr) -> f64 ---
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

EV_LEFT_DOWN, EV_LEFT_UP :: 1, 2
EV_RIGHT_DOWN, EV_RIGHT_UP :: 3, 4
EV_MOUSE_MOVED :: 5
EV_LEFT_DRAGGED, EV_RIGHT_DRAGGED :: 6, 7
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
	}
	return event
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
		1 << EV_SCROLL_WHEEL)
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
link_gen: i64
@(private)
link_host: u64
@(private)
link_ref: rawptr
@(private)
link_display: u32
@(private)
pace_mark: i64
@(private)
pace_started: bool
@(private)
last_host: u64
@(private)
timebase: Mach_Timebase

@(private)
link_callback :: proc "c" (
	link: rawptr,
	now: rawptr,
	out_time: ^CV_Time_Stamp,
	flags_in: u64,
	flags_out: ^u64,
	user: rawptr,
) -> i32 {
	if out_time != nil {
		intrinsics.atomic_store(&link_host, out_time.hostTime)
	}
	intrinsics.atomic_add(&link_gen, 1)
	return 0
}

@(private)
window_display_id :: proc() -> u32 {
	win := cast(^Foundation.Window)rl.GetWindowHandle()
	if win == nil {
		return 0
	}
	screen := Foundation.Window_screen(win)
	if screen == nil {
		return 0
	}
	desc := intrinsics.objc_send(^Foundation.Object, screen, "deviceDescription")
	if desc == nil {
		return 0
	}
	cls := cast(^Foundation.Object)Foundation.objc_lookUpClass("NSString")
	if cls == nil {
		return 0
	}
	key := intrinsics.objc_send(^Foundation.Object, cls, "stringWithUTF8String:", cstring("NSScreenNumber"))
	if key == nil {
		return 0
	}
	num := intrinsics.objc_send(^Foundation.Object, desc, "objectForKey:", key)
	if num == nil {
		return 0
	}
	return intrinsics.objc_send(u32, num, "unsignedIntValue")
}

@(private)
rebind_link :: proc() {
	if link_ref == nil {
		return
	}
	id := window_display_id()
	if id == 0 || id == link_display {
		return
	}
	CVDisplayLinkStop(link_ref)
	if CVDisplayLinkSetCurrentCGDisplay(link_ref, id) == 0 {
		link_display = id
	}
	CVDisplayLinkStart(link_ref)
}

darwin_start :: proc() {
	install_input_monitor()
	mach_timebase_info(&timebase)
	link: rawptr
	if CVDisplayLinkCreateWithActiveCGDisplays(&link) != 0 || link == nil {
		return
	}
	if CVDisplayLinkSetOutputCallback(link, link_callback, nil) != 0 {
		CVDisplayLinkRelease(link)
		return
	}
	id := window_display_id()
	if id != 0 {
		CVDisplayLinkSetCurrentCGDisplay(link, id)
		link_display = id
	}
	if CVDisplayLinkStart(link) != 0 {
		CVDisplayLinkRelease(link)
		return
	}
	link_ref = link
}

darwin_stop :: proc() {
	shutdown_input_monitor()
	if link_ref != nil {
		CVDisplayLinkStop(link_ref)
		CVDisplayLinkRelease(link_ref)
		link_ref = nil
	}
}

@(private)
host_seconds :: proc(delta: u64) -> f64 {
	if timebase.denom == 0 {
		return 0
	}
	return f64(delta) * f64(timebase.numer) / f64(timebase.denom) / 1e9
}

@(private)
vblank_step :: proc() -> i64 {
	if link_ref == nil {
		return 1
	}
	period := CVDisplayLinkGetActualOutputVideoRefreshPeriod(link_ref)
	if period <= 0 || target_fps <= 0 {
		return 1
	}
	hz := 1.0 / period
	step := i64(math_round(hz / f64(target_fps)))
	if step < 1 {
		return 1
	}
	return step
}

@(private)
math_round :: proc(v: f64) -> f64 {
	if v >= 0 {
		return f64(i64(v + 0.5))
	}
	return f64(i64(v - 0.5))
}

// Block until `vblank_step` link ticks have happened since the last sample.
// A 100ms cap keeps a dead link from freezing quit. After the wait the mark
// jumps to the current counter, so a hitch does not replay stale ticks.
darwin_pace :: proc() {
	rebind_link()
	gen := intrinsics.atomic_load(&link_gen)
	if !pace_started || link_ref == nil {
		pace_started = true
		pace_mark = gen
		last_host = intrinsics.atomic_load(&link_host)
		frame_dt = 1.0 / 60.0
		return
	}

	step := vblank_step()
	target := pace_mark + step
	deadline := time.time_add(time.now(), 100 * time.Millisecond)
	for intrinsics.atomic_load(&link_gen) < target {
		if quit_requested || time.since(deadline) >= 0 {
			break
		}
		time.sleep(200 * time.Microsecond)
	}
	pace_mark = intrinsics.atomic_load(&link_gen)

	host := intrinsics.atomic_load(&link_host)
	if last_host != 0 && host > last_host {
		dt := host_seconds(host - last_host)
		if dt > 0 && dt < 0.5 {
			frame_dt = f32(dt)
		}
	}
	last_host = host
}
