package ui

import clay "../deps/clay"
import "core:math"

// Component contract
// ------------------
// A component is a plain Odin proc that:
//   1. Emits Clay layout (during begin_layout … end_layout)
//   2. Hit-tests with previous-frame geometry (element_box / clicked / hovered)
//   3. Returns interaction results in the same call (single-call API)
//   4. Never draws itself: decorations go through Clay (rects, text, floating
//      children, or the Custom primitives below), so they draw in Clay's order
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

// The pointer is over the element, as Clay hit-tests it: not under a
// capturing floating menu, not scrolled out of its clip.
hovered :: proc(id: string, index: u32 = 0) -> bool {
	return clay.PointerOver(clay.ID(id, index))
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

// Call once per interactive control during build. Starts a drag on a press
// over the element (as Clay sees it: not under a capturing floating menu, not
// scrolled out of its clip), clears on release. Returns true while this id
// owns the drag.
drag_update :: proc(id: string) -> bool {
	hash := clay.ID(id).id
	if mouse_released(.Left) && _drag_id == hash {
		_drag_id = 0
	}
	if _drag_id == 0 && mouse_pressed(.Left) && hovered(id) {
		_drag_id = hash
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

// --- Clay Custom elements ---------------------------------------------------
//
// What a Custom element draws, in its box and Clay's draw order, clipped like
// any element. Clay carries a pointer to a Custom; geometry is relative to
// the element's box, so it moves and clips with it.
//
// A host draws its own element with a Custom_Draw it keeps alive for the
// frame (in a struct of its own):
//
//   board.custom = ui.Custom_Draw{draw = board_draw, data = &board}
//   if clay.UI(clay.ID("Board"))({layout = ..., custom = {customData = &board.custom}}) {}
//
// `draw` gets the data and the element's box, in layout units. What it
// draws with ui.draw_* lands in Clay's order. One that draws with raylib
// calls flush_shapes first, so what the ui queued before it is drawn under
// it. The ui doesn't do that for every Custom element: a flush mid-frame
// re-uploads into a buffer the GPU is still reading, a stall on macOS of
// most of a millisecond.

Custom :: union {
	Custom_Draw,
	Custom_Triangle,
	Custom_Gradient,
	^Rich_Layout,
}

Custom_Draw :: struct {
	draw: proc(data: rawptr, box: Region_Box),
	data: rawptr,
}

// Corners as offsets from the box's top-left.
@(private)
Custom_Triangle :: struct {
	a, b, c: [2]f32,
	color:   Color,
}

// A horizontal gradient through the stops, as a pill.
@(private)
Custom_Gradient :: struct {
	stops: [GRADIENT_STOPS]Color,
	count: u8,
}

@(private)
GRADIENT_STOPS :: 7

// The ui's own Customs for this frame. Capacity is reserved up front and only
// ever cleared (never shrunk), so pointers handed to Clay stay valid for the
// whole frame — a mid-frame realloc would dangle them (use-after-free).
@(private)
s_custom: [dynamic]Custom

CUSTOM_RESERVE :: 256

@(private)
custom_setup :: proc() {
	reserve(&s_custom, CUSTOM_RESERVE)
}

@(private)
custom_teardown :: proc() {
	rich_teardown()
	delete(s_custom)
	s_custom = nil
}

@(private)
custom_begin_frame :: proc() {
	rich_begin_frame()
	clear(&s_custom)
	if cap(s_custom) < CUSTOM_RESERVE {
		reserve(&s_custom, CUSTOM_RESERVE)
	}
}

@(private)
custom_push :: proc(d: Custom) -> rawptr {
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
// A plain element whose corners are half its size: the renderer draws round
// corners exactly, so a circle needs nothing Custom.
@(private)
circle_at :: proc(id, parent_id: string, cx, cy, r: f32, color: Color, index: u32 = 0) {
	parent, ok := element_box(parent_id)
	if !ok {
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
		backgroundColor = color,
		cornerRadius    = clay.CornerRadiusAll(r),
	}) {}
}

// Filled triangle as a floating child. Points are absolute layout coords;
// converted to parent-relative offsets for the Custom payload.
@(private)
triangle_at :: proc(id, parent_id: string, a, b, c: [2]f32, color: Color, index: u32 = 0) {
	parent, ok := element_box(parent_id)
	if !ok {
		return
	}
	min_x := min(a.x, b.x, c.x)
	min_y := min(a.y, b.y, c.y)
	max_x := max(a.x, b.x, c.x)
	max_y := max(a.y, b.y, c.y)
	// Local offsets inside the floating element's own box.
	ptr := custom_push(Custom_Triangle{
		a     = {a.x - min_x, a.y - min_y},
		b     = {b.x - min_x, b.y - min_y},
		c     = {c.x - min_x, c.y - min_y},
		color = color,
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

// Draw a Clay .Custom command; render calls this.
@(private)
dispatch_custom :: proc(cmd: ^clay.RenderCommand) {
	c := cast(^Custom)cmd.renderData.custom.customData
	if c == nil {
		return
	}
	box := cmd.boundingBox
	switch &d in c^ {
	case Custom_Draw:
		if d.draw != nil { d.draw(d.data, box) }
	case Custom_Triangle:
		draw_triangle({box.x + d.a.x, box.y + d.a.y}, {box.x + d.b.x, box.y + d.b.y}, {box.x + d.c.x, box.y + d.c.y}, d.color)
	case Custom_Gradient:
		draw_gradient_pill(box, d.stops[:d.count])
	case ^Rich_Layout:
		draw_rich(d, box)
	}
}
