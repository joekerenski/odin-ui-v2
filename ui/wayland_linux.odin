package ui

// Wayland extras on top of raylib/GLFW, active when GLFW picked its Wayland
// backend (WAYLAND_DISPLAY set). Under X11 the frame loop is plain raylib.
//
//   - the surface's frame callback as the frame clock, with swap interval 0
//   - fullscreen through GLFW directly, not raylib's ToggleFullscreen
//
// EGL's own vsync is the driver's, and NVIDIA's egl-wayland2 runs swap
// interval 1 at half the refresh on Hyprland (30fps on a 60Hz screen; the
// older egl-wayland and XWayland hold 60). Seen with egl-wayland2 1.0.2,
// nvidia-open 610.57.04, Hyprland 0.56.2; README has the full stack and
// tools/vsync_probe rechecks it. The frame callback is the
// compositor's own "draw now", the clock Wayland intends. `end_draw` asks for
// one before the swap, so the swap's commit carries it, and `frame` waits for
// it, then polls input. Presents on Wayland never tear, vsync or not.
//
// The callback lives on our own event queue, through a wrapper of GLFW's
// wl_surface, so GLFW's event dispatch never sees it. A hidden surface gets
// no callbacks; the wait gives up after 100ms and keeps the one outstanding
// callback rather than stacking more. A target_fps below the refresh adds a
// deadline grid after the callback.
//
// raylib's fullscreen mode drops HiDPI: screen size becomes the physical
// framebuffer and the mouse scale 1. Wayland cursor positions stay logical,
// so at scale 1.25 every click lands at 0.8x of where it points. raylib's
// Wayland correction sits behind `_GLFW_WAYLAND && !_GLFW_X11`, compiled out
// of our X11 + Wayland build. glfwSetWindowMonitor without raylib's flag
// keeps raylib on its windowed HiDPI path, the same as a compositor
// fullscreen (Hyprland's SUPER+F), which raylib never hears about.

import "core:c"
import "core:math"
import "core:sys/posix"
import "core:time"
import rl "../deps/raylib"

foreign import wayland "system:wayland-client"

// GLFW is linked in from libraylib.a.
@(default_calling_convention = "c")
foreign {
	glfwGetPlatform :: proc() -> c.int ---
	glfwGetWaylandDisplay :: proc() -> rawptr ---
	glfwGetCurrentContext :: proc() -> rawptr ---
	glfwGetPrimaryMonitor :: proc() -> rawptr ---
	glfwGetWindowMonitor :: proc(window: rawptr) -> rawptr ---
	glfwSetWindowMonitor :: proc(window: rawptr, monitor: rawptr, x, y, width, height, refresh_rate: c.int) ---
}

GLFW_PLATFORM_WAYLAND :: 0x00060003
GLFW_DONT_CARE :: -1

@(private = "file")
Wl_Interface :: struct {
	name:         cstring,
	version:      c.int,
	method_count: c.int,
	methods:      rawptr,
	event_count:  c.int,
	events:       rawptr,
}

@(private = "file")
Wl_Callback_Listener :: struct {
	done: proc "c" (data: rawptr, callback: rawptr, time_ms: u32),
}

@(private = "file")
WL_SURFACE_FRAME :: 3

@(default_calling_convention = "c")
@(private = "file")
foreign wayland {
	wl_callback_interface: Wl_Interface

	wl_display_create_queue :: proc(display: rawptr) -> rawptr ---
	wl_event_queue_destroy :: proc(queue: rawptr) ---
	wl_display_get_fd :: proc(display: rawptr) -> c.int ---
	wl_display_flush :: proc(display: rawptr) -> c.int ---
	wl_display_prepare_read_queue :: proc(display: rawptr, queue: rawptr) -> c.int ---
	wl_display_read_events :: proc(display: rawptr) -> c.int ---
	wl_display_cancel_read :: proc(display: rawptr) ---
	wl_display_dispatch_queue_pending :: proc(display: rawptr, queue: rawptr) -> c.int ---
	wl_proxy_create_wrapper :: proc(proxy: rawptr) -> rawptr ---
	wl_proxy_wrapper_destroy :: proc(wrapper: rawptr) ---
	wl_proxy_set_queue :: proc(proxy: rawptr, queue: rawptr) ---
	wl_proxy_get_version :: proc(proxy: rawptr) -> u32 ---
	wl_proxy_add_listener :: proc(proxy: rawptr, implementation: rawptr, data: rawptr) -> c.int ---
	wl_proxy_destroy :: proc(proxy: rawptr) ---
	wl_proxy_marshal_flags :: proc(proxy: rawptr, opcode: u32, interface: ^Wl_Interface, version: u32, flags: u32, #c_vararg args: ..any) -> rawptr ---
}

@(private = "file")
wl: struct {
	display:   rawptr,
	queue:     rawptr,
	surface:   rawptr, // wrapper on our queue
	callback:  rawptr, // outstanding frame callback, nil once done
	refresh:   f64,
	window:    rawptr, // GLFWwindow; raylib's context is the only one
	windowed:  [2]c.int,
	last_wake: time.Tick,
	next_slot: time.Tick,
}

@(private = "file")
frame_listener := Wl_Callback_Listener{done = frame_done}

@(private = "file")
frame_done :: proc "c" (data: rawptr, callback: rawptr, time_ms: u32) {
	wl_proxy_destroy(callback)
	wl.callback = nil
}

wayland_active :: proc() -> bool {
	return wl.surface != nil
}

// After InitWindow. Does nothing unless GLFW is on Wayland.
wayland_start :: proc() {
	if glfwGetPlatform() != GLFW_PLATFORM_WAYLAND {
		return
	}
	display := glfwGetWaylandDisplay()
	surface := rl.GetWindowHandle() // the wl_surface on Wayland
	if display == nil || surface == nil {
		return
	}
	// Clear the flag, not just the interval: ToggleFullscreen turns swap
	// interval 1 back on while it is set, and that wait stacked on the
	// callback's swung fullscreen between 30 and 50+ fps.
	rl.ClearWindowState({.VSYNC_HINT})
	wl.display = display
	wl.window = glfwGetCurrentContext()
	wl.queue = wl_display_create_queue(display)
	wl.surface = wl_proxy_create_wrapper(surface)
	wl_proxy_set_queue(wl.surface, wl.queue)
	// Read once: GetCurrentMonitor asks for the window position, which
	// Wayland does not give, and GLFW logs that every call.
	wl.refresh = f64(rl.GetMonitorRefreshRate(rl.GetCurrentMonitor()))
}

// Before CloseWindow: GLFW disconnects the display.
wayland_stop :: proc() {
	if wl.surface == nil {
		return
	}
	if wl.callback != nil {
		wl_proxy_destroy(wl.callback)
	}
	wl_proxy_wrapper_destroy(wl.surface)
	wl_event_queue_destroy(wl.queue)
	wl = {}
}

// The primary output: Wayland gives no window position, so there is no
// telling which output the window is on (raylib's GetCurrentMonitor guesses
// from the position too).
wayland_toggle_fullscreen :: proc() {
	if wayland_is_fullscreen() {
		glfwSetWindowMonitor(wl.window, nil, 0, 0, wl.windowed.x, wl.windowed.y, GLFW_DONT_CARE)
		return
	}
	// Logical size: raylib's screen size is in points on the HiDPI path.
	wl.windowed = {rl.GetScreenWidth(), rl.GetScreenHeight()}
	monitor := glfwGetPrimaryMonitor()
	if monitor != nil {
		glfwSetWindowMonitor(wl.window, monitor, 0, 0, wl.windowed.x, wl.windowed.y, GLFW_DONT_CARE)
	}
}

// Only fullscreen asked for through GLFW; a compositor fullscreen (SUPER+F)
// is invisible to the client.
wayland_is_fullscreen :: proc() -> bool {
	return glfwGetWindowMonitor(wl.window) != nil
}

// Before the swap, so the swap's commit carries the request.
wayland_request_frame :: proc() {
	if wl.callback != nil {
		return
	}
	wl.callback = wl_proxy_marshal_flags(
		wl.surface, WL_SURFACE_FRAME, &wl_callback_interface,
		wl_proxy_get_version(wl.surface), 0, rawptr(nil),
	)
	wl_proxy_add_listener(wl.callback, &frame_listener, nil)
}

// Wait for the compositor's frame callback (at most 100ms), then for the
// next grid slot when target_fps is below the refresh. Sets frame_dt.
wayland_pace :: proc() {
	if wl.callback != nil {
		limit := time.tick_add(time.tick_now(), 100 * time.Millisecond)
		for wl.callback != nil && !quit_requested {
			left := time.tick_diff(time.tick_now(), limit)
			if left <= 0 {
				break
			}
			wait_queue(left)
		}
	}

	now := time.tick_now()
	if target_fps > 0 && wl.refresh > 0 && f64(target_fps) < wl.refresh * 0.9 {
		period := time.Duration(f64(time.Second) / f64(target_fps))
		if wl.next_slot == {} || time.tick_diff(wl.next_slot, now) > period {
			wl.next_slot = now // missed a whole slot: restart the grid here
		}
		if wait := time.tick_diff(now, wl.next_slot); wait > 0 {
			time.accurate_sleep(wait)
		}
		wl.next_slot = time.tick_add(wl.next_slot, period)
		now = time.tick_now()
	} else {
		wl.next_slot = {}
	}

	frame_dt = 1.0 / 60.0
	if wl.last_wake != {} {
		dt := time.duration_seconds(time.tick_diff(wl.last_wake, now))
		// Callbacks land on vblanks; snap to them so dispatch jitter stays
		// out of the sim step.
		if wl.refresh > 0 {
			n := math.round(dt * wl.refresh)
			if n >= 1 && math.abs(dt * wl.refresh - n) < 0.25 {
				dt = n / wl.refresh
			}
		}
		if dt > 0 && dt < 0.5 {
			frame_dt = f32(dt)
		}
	}
	wl.last_wake = now
}

// One round of reading the display socket into our queue and dispatching it.
@(private = "file")
wait_queue :: proc(timeout: time.Duration) {
	for wl_display_prepare_read_queue(wl.display, wl.queue) != 0 {
		wl_display_dispatch_queue_pending(wl.display, wl.queue)
		if wl.callback == nil {
			return
		}
	}
	wl_display_flush(wl.display)
	fd := posix.pollfd{fd = posix.FD(wl_display_get_fd(wl.display)), events = {.IN}}
	ms := c.int(math.ceil(time.duration_milliseconds(timeout)))
	if posix.poll(&fd, 1, ms) > 0 {
		wl_display_read_events(wl.display)
	} else {
		wl_display_cancel_read(wl.display)
	}
	wl_display_dispatch_queue_pending(wl.display, wl.queue)
}
