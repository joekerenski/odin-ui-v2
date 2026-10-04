package ui

import clay "../deps/clay"
import "core:math"

// Component contract
// ------------------
// A component is a plain Odin proc that:
//   1. Emits Clay layout (during begin_layout … end_layout)
//   2. Hit-tests with previous-frame geometry (element_box / clicked / hovered)
//   3. Returns interaction results in the same call (single-call API)
//   4. Never touches a backend API — decorations go through Clay (rects, text,
//      floating children, or Custom primitives below) so every backend renders them
//
// Example:
//
//   stepper :: proc(id: string, value, step, lo, hi: f32) -> f32 {
//       out := value
//       if clay.UI(clay.ID(id))({ layout = {...}, childGap = 4, ...}) {
//           if button(fmt.tprintf("%s-", id), "−") { out = math.max(lo, value - step) }
//           text(fmt.tprintf("%.0f", value), ...)
//           if button(fmt.tprintf("%s+", id), "+") { out = math.min(hi, value + step) }
//       }
//       return out
//   }
//
// Host-owned state (dropdown open, text-field buffer) lives in a pointer the
// caller passes in. Ephemeral drag state is kept inside the lib (one mouse).

// --- interaction (previous-frame geometry) ----------------------------------

hovered :: proc(id: string, index: u32 = 0) -> bool {
	return element_hovered(id, index)
}

// True while LMB is held over the element, or while a drag started on it.
dragging :: proc(id: string) -> bool {
	return _drag_id != 0 && _drag_id == clay.ID(id).id && mouse_down(.Left)
}

// --- drag state (single active drag; one mouse) -----------------------------

// Clay's hash of the id, not the string: ids built with tprintf live in the
// temp allocator, which the host frees every frame.
@(private)
_drag_id: u32

// Call once per interactive control during build. Starts a drag on press-in-box,
// clears on release. Returns true while this id owns the drag.
drag_update :: proc(id: string) -> bool {
	hash := clay.ID(id).id
	box, ok := element_box(id)
	if mouse_released(.Left) && _drag_id == hash {
		_drag_id = 0
	}
	if _drag_id == 0 && mouse_pressed(.Left) && ok && mouse_in_box(box) {
		if s_interactions_enabled {
			_drag_id = hash
		}
	}
	return _drag_id == hash && mouse_down(.Left)
}

// Map mouse X across `id`'s box to [lo, hi]. No-op when not dragging this id.
drag_value_x :: proc(id: string, value, lo, hi: f32, inset: f32 = 0) -> f32 {
	if !drag_update(id) {
		return value
	}
	box, ok := element_box(id)
	if !ok || box.width <= 2 * inset {
		return value
	}
	// `inset`: the track's ends sit this far in from the box (a knob's radius).
	t := math.clamp((input.mouse_x - box.x - inset) / (box.width - 2 * inset), 0, 1)
	return lo + t * (hi - lo)
}

// --- Clay Custom primitives (backend-rendered) ------------------------------
//
// Geometry is *relative to the command's bounding box* so floating children
// clip with their parent (panel fold, scroll). Stored in a frame arena so
// pointers stay valid from layout → render. Cleared at begin_layout.

Custom_Kind :: enum u8 {
	// Filled circle centered in the element's box; r = min(w,h)/2.
	Circle,
	// Triangle; a/b/c are offsets from the box's top-left.
	Triangle,
	// Horizontal gradient through `stops`, as a pill (ends rounded to half
	// the height).
	Gradient,
}

GRADIENT_STOPS :: 7

Custom_Data :: struct {
	kind:    Custom_Kind,
	color:   Color,
	// Triangle only — offsets from bounding-box origin.
	a, b, c: [2]f32,
	// Gradient only.
	stops:   [GRADIENT_STOPS]Color,
	count:   u8,
}

// Backing store for Custom payloads. Capacity is reserved up front and only
// ever cleared (never shrunk), so pointers handed to Clay stay valid for the
// whole frame — a mid-frame realloc would dangle them (use-after-free).
@(private)
s_custom: [dynamic]Custom_Data

CUSTOM_RESERVE :: 256

@(private)
custom_setup :: proc() {
	reserve(&s_custom, CUSTOM_RESERVE)
}

@(private)
custom_teardown :: proc() {
	delete(s_custom)
	s_custom = nil
}

@(private)
custom_begin_frame :: proc() {
	clear(&s_custom)
	if cap(s_custom) < CUSTOM_RESERVE {
		reserve(&s_custom, CUSTOM_RESERVE)
	}
}

@(private)
custom_push :: proc(d: Custom_Data) -> rawptr {
	if len(s_custom) >= cap(s_custom) {
		// Growing here would invalidate pointers already handed to Clay this
		// frame. Drop the decoration instead (raise CUSTOM_RESERVE if hit).
		return nil
	}
	append(&s_custom, d)
	return &s_custom[len(s_custom) - 1]
}

// Filled circle as a floating child of `parent_id`, centered at layout-space
// (cx, cy). Size is 2*r. clipTo is .AttachedParent: that clips to the parent's
// enclosing clip region (a scroll container), not to the parent's own box, so
// a knob still hangs past its track's ends but scrolls out under the edge.
custom_circle_at :: proc(id, parent_id: string, cx, cy, r: f32, color: Color, index: u32 = 0) {
	parent, ok := element_box(parent_id)
	if !ok {
		return
	}
	ptr := custom_push({kind = .Circle, color = color})
	if ptr == nil {
		return
	}
	d := max(1, r * 2)
	// Offset from parent top-left so the circle center lands on (cx, cy).
	ox := (cx - parent.x) - r
	oy := (cy - parent.y) - r
	if clay.UI(clay.ID(id, index))(clay.ElementDeclaration{
		layout = {
			sizing = {width = clay.SizingFixed(d), height = clay.SizingFixed(d)},
		},
		floating = {
			attachTo   = .ElementWithId,
			parentId   = clay.ID(parent_id).id,
			offset     = {ox, oy},
			zIndex     = 10,
			attachment = {element = .LeftTop, parent = .LeftTop},
			clipTo     = .AttachedParent,
			// Decoration: hovering it still hovers the control under it.
			pointerCaptureMode = .Passthrough,
		},
		custom = {customData = ptr},
	}) {}
}

// Filled triangle as a floating child. Points are absolute layout coords;
// converted to parent-relative offsets for the Custom payload.
custom_triangle_at :: proc(id, parent_id: string, a, b, c: [2]f32, color: Color, index: u32 = 0) {
	parent, ok := element_box(parent_id)
	if !ok {
		return
	}
	min_x := min(a.x, b.x, c.x)
	min_y := min(a.y, b.y, c.y)
	max_x := max(a.x, b.x, c.x)
	max_y := max(a.y, b.y, c.y)
	// Local offsets inside the floating element's own box.
	ptr := custom_push({
		kind  = .Triangle,
		color = color,
		a     = {a.x - min_x, a.y - min_y},
		b     = {b.x - min_x, b.y - min_y},
		c     = {c.x - min_x, c.y - min_y},
	})
	if ptr == nil {
		return
	}
	ox := min_x - parent.x
	oy := min_y - parent.y
	if clay.UI(clay.ID(id, index))(clay.ElementDeclaration{
		layout = {
			sizing = {
				width  = clay.SizingFixed(max(1, max_x - min_x)),
				height = clay.SizingFixed(max(1, max_y - min_y)),
			},
		},
		floating = {
			attachTo   = .ElementWithId,
			parentId   = clay.ID(parent_id).id,
			offset     = {ox, oy},
			zIndex     = 10,
			attachment = {element = .LeftTop, parent = .LeftTop},
			clipTo     = .AttachedParent,
			// Decoration: hovering it still hovers the control under it.
			pointerCaptureMode = .Passthrough,
		},
		custom = {customData = ptr},
	}) {}
}

// Dispatch a Clay .Custom command — called from each backend's clay renderer.
// Geometry is relative to cmd.boundingBox.
@(private)
dispatch_custom :: proc(cmd: ^clay.RenderCommand) {
	data := cast(^Custom_Data)cmd.renderData.custom.customData
	if data == nil {
		return
	}
	box := cmd.boundingBox
	switch data.kind {
	case .Circle:
		cx := box.x + box.width * 0.5
		cy := box.y + box.height * 0.5
		r := min(box.width, box.height) * 0.5
		draw_circle(cx, cy, r, data.color)
	case .Triangle:
		draw_triangle(
			{box.x + data.a.x, box.y + data.a.y},
			{box.x + data.b.x, box.y + data.b.y},
			{box.x + data.c.x, box.y + data.c.y},
			data.color,
		)
	case .Gradient:
		draw_gradient_pill(box, data.stops[:data.count])
	}
}
