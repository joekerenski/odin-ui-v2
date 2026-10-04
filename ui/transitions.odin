package ui

import clay "../deps/clay"
import "base:runtime"
import "core:math"

// Fade via overlay multiply (our renderers: color *= overlay/255).
//
// Clay quirk: OverlayColorStart is only emitted when overlayColor.a > 0
// (see clay.h render path). Alpha 0 therefore means "no overlay command" =
// full-opacity draw under multiply. That produces the classic flicker:
//
//   open → full (a=0, no cmd) → dim (enter starts) → fade to full
//
// So "invisible" must be a tiny positive alpha (FADE_INVISIBLE), never 0.

// 1/255 ≈ invisible under multiply; still forces Clay to emit the overlay cmd.
FADE_INVISIBLE :: 1.0
FADE_OPAQUE :: 255.0

fade_ease_out :: proc(t_in: f32) -> f32 {
	t := math.clamp(t_in, 0.0, 1.0)
	return 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t)
}

// Clamp overlay alpha into the range Clay will actually emit, while keeping
// near-zero values effectively invisible under multiply.
fade_alpha :: proc(a: f32) -> f32 {
	if a <= 0 {
		return FADE_INVISIBLE
	}
	return math.min(a, FADE_OPAQUE)
}

fade_handler :: proc "c" (args: clay.TransitionCallbackArguments) -> bool {
	context = runtime.default_context()
	dt := math.max(args.duration, 0.0001)
	t := math.clamp(args.elapsedTime / dt, 0.0, 1.0)
	a0 := args.initial.overlayColor[3]
	a1 := args.target.overlayColor[3]
	a := a0 + (a1 - a0) * fade_ease_out(t)
	args.current.overlayColor = {255, 255, 255, fade_alpha(a)}
	return t >= 1.0
}

fade_enter_initial :: proc "c" (
	initialState: clay.TransitionData,
	properties: clay.TransitionPropertyFlags,
) -> clay.TransitionData {
	out := initialState
	// Start effectively invisible (NOT 0 — see FADE_INVISIBLE note above).
	out.overlayColor = {255, 255, 255, FADE_INVISIBLE}
	return out
}

fade_exit_final :: proc "c" (
	finalState: clay.TransitionData,
	properties: clay.TransitionPropertyFlags,
) -> clay.TransitionData {
	out := finalState
	out.overlayColor = {255, 255, 255, FADE_INVISIBLE}
	return out
}

// A fade in when the element appears. It disappears at once, unless `fade_out`: an element
// fading out is no longer declared, so Clay draws its last frame again, with the text pointers
// that frame had. Text made for that frame (tprintf, a temp string, anything freed or reused
// since) is then garbage, drawn as boxes. Fade out only what shows text that outlives the fade
// (string constants, strings the app keeps).
fade_transition :: proc(duration: f32 = 0.18, fade_out := false) -> clay.TransitionElementConfig {
	return clay.TransitionElementConfig{
		duration   = duration,
		properties = {.OverlayColor},
		handler    = fade_handler,
		// Nothing moves, so a menu fading in already takes the pointer (and
		// keeps clicks off what's under it). Exiting still lets it through.
		interactionHandling = .AllowInteractionsWhileTransitioningPosition,
		enter = {
			setInitialState = fade_enter_initial,
			// Fire even when the parent also just appeared (modals, menus).
			trigger         = .TriggerOnFirstParentFrame,
		},
		exit = {
			setFinalState = fade_exit_final if fade_out else nil,
			trigger       = .TriggerWhenParentExits,
		},
	}
}

// Multiply-fade overlay color for app-driven fades (not Clay transitions).
// Always returns a > 0 so Clay emits the overlay command.
//   k=0 → invisible, k=1 → opaque
fade_overlay :: proc(k: f32) -> Color {
	a := fade_alpha(math.clamp(k, 0.0, 1.0) * FADE_OPAQUE)
	return {255, 255, 255, a}
}

// --- app-side tweens ---------------------------------------------------------
//
// These are frame-rate independent, driven from ui.frame_dt. Feed the eased `k`
// into a layout input every frame: Clay re-lays out each frame, so animating a
// width/height/position *input* animates the whole layout in sync (canvas grows
// as the sidebar folds, no snapping). Clay's own dimension transitions only
// animate the drawn box while the layout reflow jumps to the target — fine for a
// drawer, wrong for a collapsing sidebar.

ease_in_out_cubic :: proc(t_in: f32) -> f32 {
	t := math.clamp(t_in, 0.0, 1.0)
	if t < 0.5 {
		return 4.0 * t * t * t
	}
	return 1.0 - math.pow(-2.0 * t + 2.0, 3.0) * 0.5
}

// Advance a seconds-clock toward `target_seconds` by `dt` (works both ways).
tween_clock :: proc(clock, target_seconds, dt: f32) -> f32 {
	if clock < target_seconds {
		return math.min(clock + dt, target_seconds)
	}
	return math.max(clock - dt, target_seconds)
}
