package ui

import clay "../deps/clay"
import "core:math"
import "core:strings"
import rl "../deps/raylib"
import rlgl "../deps/raylib/rlgl"

// Clay render commands to raylib. Text quads are snapped onto the physical
// pixel grid. Filled rects use raylib's rounded-rect path (uniform corners,
// 16 segments). Per-side borders are rects plus rings.

to_rl_color :: proc(color: Color) -> rl.Color {
	return {u8(color[0]), u8(color[1]), u8(color[2]), u8(color[3])}
}

draw_circle :: proc(x, y, r: f32, color: Color) {
	rl.DrawCircleV({x, y}, r, to_rl_color(color))
}

// Any vertex order. raylib wants counter-clockwise on screen and culls the
// other winding, which dropped the left chevron and the dropdown's.
draw_triangle :: proc(a, b, c: [2]f32, color: Color) {
	b, c := b, c
	if (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) > 0 {
		b, c = c, b
	}
	rl.DrawTriangle({a.x, a.y}, {b.x, b.y}, {c.x, c.y}, to_rl_color(color))
}

// Round a layout-space coordinate onto the physical pixel grid.
snap_px :: proc(v: f32) -> f32 {
	s := raster_scale()
	return math.round(v * s) / s
}

// The stack holds each overlay already multiplied into its parents, so the
// top is the whole effect.
@(private)
apply_overlay :: proc(color: Color, overlay: [dynamic]Color) -> Color {
	if len(overlay) == 0 {
		return color
	}
	o := overlay[len(overlay) - 1]
	if o[0] == 0 && o[1] == 0 && o[2] == 0 && o[3] == 0 {
		return {0, 0, 0, 0}
	}
	return {
		color[0] * o[0] / 255.0,
		color[1] * o[1] / 255.0,
		color[2] * o[2] / 255.0,
		color[3] * o[3] / 255.0,
	}
}

// Scissor takes points, not layout units, so it applies the zoom itself.
@(private)
set_scissor :: proc(b: clay.BoundingBox) {
	rl.BeginScissorMode(
		i32(math.round(b.x * zoom)),
		i32(math.round(b.y * zoom)),
		i32(math.round(b.width * zoom)),
		i32(math.round(b.height * zoom)),
	)
}

// Clip boxes nest: each is intersected with its parent, and closing one
// restores the parent instead of turning clipping off.
//
// A scissor change flushes raylib's batch. Every clipped floating element
// (each slider knob, each segment label) is its own Clay root, bracketed in
// its own scissor start and end, mostly with the same box as the one before.
// So the scissor is only set when something draws, and only when it differs
// from the one in effect: 80 knobs cost no flushes instead of 160.
render :: proc(commands: ^clay.ClayArray(clay.RenderCommand), allocator := context.temp_allocator) {
	overlay := make([dynamic]Color, allocator)
	clips := make([dynamic]clay.BoundingBox, allocator)
	active: Maybe(clay.BoundingBox)
	sync :: proc(active: ^Maybe(clay.BoundingBox), clips: [dynamic]clay.BoundingBox) {
		want: Maybe(clay.BoundingBox)
		if len(clips) > 0 {
			want = clips[len(clips) - 1]
		}
		if active^ == want {
			return
		}
		active^ = want
		if box, ok := want.?; ok {
			set_scissor(box)
		} else {
			rl.EndScissorMode()
		}
	}
	defer if active != nil {
		rl.EndScissorMode()
	}
	for i in 0 ..< commands.length {
		cmd := clay.RenderCommandArray_Get(commands, i32(i))
		b := cmd.boundingBox
		switch cmd.commandType {
		case .None:
		case .Text:
			sync(&active, clips)
			config := cmd.renderData.text
			t := string(config.stringContents.chars[:config.stringContents.length])
			if int(config.fontId) >= len(fonts) || fonts[config.fontId].font.glyphCount <= 0 {
				continue
			}
			cstr := strings.clone_to_cstring(t, allocator)
			rl.DrawTextEx(
				fonts[config.fontId].font,
				cstr,
				{snap_px(b.x), snap_px(b.y)},
				text_draw_size(config.fontId, config.fontSize),
				f32(config.letterSpacing),
				to_rl_color(apply_overlay(config.textColor, overlay)),
			)
		case .Image:
			sync(&active, clips)
			tex := (^rl.Texture2D)(cmd.renderData.image.imageData)
			if tex == nil || tex.width == 0 {
				continue
			}
			tint: Color = {255, 255, 255, 255}
			if len(overlay) > 0 {
				tint = overlay[len(overlay) - 1]
			}
			rl.DrawTextureEx(tex^, {b.x, b.y}, 0, b.width / f32(tex.width), to_rl_color(tint))
		case .ScissorStart:
			r := b
			if len(clips) > 0 {
				p := clips[len(clips) - 1]
				x0, y0 := max(r.x, p.x), max(r.y, p.y)
				x1, y1 := min(r.x + r.width, p.x + p.width), min(r.y + r.height, p.y + p.height)
				r = {x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
			}
			append(&clips, r)
		case .ScissorEnd:
			if len(clips) > 0 {
				pop(&clips)
			}
		case .Rectangle:
			sync(&active, clips)
			config := cmd.renderData.rectangle
			draw_round_rect(b, config.cornerRadius, apply_overlay(config.backgroundColor, overlay))
		case .Border:
			sync(&active, clips)
			config := cmd.renderData.border
			draw_border(b, config, apply_overlay(config.color, overlay))
		case .OverlayColorStart:
			c := cmd.renderData.overlayColor.color
			if len(overlay) > 0 {
				p := overlay[len(overlay) - 1]
				c = {c[0] * p[0] / 255, c[1] * p[1] / 255, c[2] * p[2] / 255, c[3] * p[3] / 255}
			}
			append(&overlay, c)
		case .OverlayColorEnd:
			if len(overlay) > 0 {
				pop(&overlay)
			}
		case .Custom:
			sync(&active, clips)
			dispatch_custom(cmd)
		}
	}
}

// Fills are rlgl triangles on the 1x1 white texture with an explicit texcoord,
// so they never sample whatever atlas was bound last. Rounded corners are
// triangle fans, which is why this path exists instead of DrawRectangle.
@(private)
fill_begin :: proc(c: rl.Color) {
	rlgl.SetTexture(shapes_tex.id)
	rlgl.Begin(rlgl.TRIANGLES)
	rlgl.Color4ub(c.r, c.g, c.b, c.a)
}

@(private)
fill_vert :: proc(x, y: f32) {
	rlgl.TexCoord2f(0.5, 0.5)
	rlgl.Vertex2f(x, y)
}

@(private)
fill_end :: proc() {
	rlgl.End()
	rlgl.SetTexture(0)
}

@(private)
fill_rect :: proc(x, y, w, h: f32, c: rl.Color) {
	if w <= 0 || h <= 0 || c.a == 0 || shapes_tex.id == 0 {
		return
	}
	fill_begin(c)
	fill_vert(x, y)
	fill_vert(x, y + h)
	fill_vert(x + w, y)
	fill_vert(x + w, y)
	fill_vert(x, y + h)
	fill_vert(x + w, y + h)
	fill_end()
}

@(private)
fill_corner :: proc(cx, cy, radius, a0, a1: f32, c: rl.Color) {
	if radius <= 0 || c.a == 0 || shapes_tex.id == 0 {
		return
	}
	segs :: 8
	fill_begin(c)
	for i in 0 ..< segs {
		t0 := (a0 + (a1 - a0) * f32(i) / segs) * math.RAD_PER_DEG
		t1 := (a0 + (a1 - a0) * f32(i + 1) / segs) * math.RAD_PER_DEG
		fill_vert(cx, cy)
		fill_vert(cx + math.cos(t1) * radius, cy + math.sin(t1) * radius)
		fill_vert(cx + math.cos(t0) * radius, cy + math.sin(t0) * radius)
	}
	fill_end()
}

// A horizontal gradient through `stops` (evenly spaced), with round ends in
// the first and last color. Vertex colors, so it is smooth at any width.
@(private)
draw_gradient_pill :: proc(b: clay.BoundingBox, stops: []Color) {
	if len(stops) == 0 || b.width <= 0 || b.height <= 0 || shapes_tex.id == 0 {
		return
	}
	r := min(b.height, b.width) * 0.5
	x0, x1 := b.x + r, b.x + b.width - r
	y0, y1 := b.y, b.y + b.height
	fill_corner(x0, b.y + r, r, 90, 270, to_rl_color(stops[0]))
	fill_corner(x1, b.y + r, r, 270, 450, to_rl_color(stops[len(stops) - 1]))
	if len(stops) == 1 {
		fill_rect(x0, y0, x1 - x0, y1 - y0, to_rl_color(stops[0]))
		return
	}
	seg := (x1 - x0) / f32(len(stops) - 1)
	rlgl.SetTexture(shapes_tex.id)
	rlgl.Begin(rlgl.TRIANGLES)
	for i in 0 ..< len(stops) - 1 {
		a, c := to_rl_color(stops[i]), to_rl_color(stops[i + 1])
		xa, xc := x0 + seg * f32(i), x0 + seg * f32(i + 1)
		vert :: proc(x, y: f32, col: rl.Color) {
			rlgl.Color4ub(col.r, col.g, col.b, col.a)
			rlgl.TexCoord2f(0.5, 0.5)
			rlgl.Vertex2f(x, y)
		}
		vert(xa, y0, a)
		vert(xa, y1, a)
		vert(xc, y0, c)
		vert(xc, y0, c)
		vert(xa, y1, a)
		vert(xc, y1, c)
	}
	rlgl.End()
	rlgl.SetTexture(0)
}

@(private)
draw_round_rect :: proc(b: clay.BoundingBox, rad: clay.CornerRadius, col: Color) {
	if b.width <= 0 || b.height <= 0 || col[3] <= 0 {
		return
	}
	rlc := to_rl_color(col)
	r := rad.topLeft
	uniform := r == rad.topRight && r == rad.bottomLeft && r == rad.bottomRight
	if !uniform || r <= 0 {
		fill_rect(b.x, b.y, b.width, b.height, rlc)
		return
	}
	r = min(r, b.width * 0.5, b.height * 0.5)
	fill_rect(b.x + r, b.y, b.width - 2 * r, b.height, rlc)
	fill_rect(b.x, b.y + r, r, b.height - 2 * r, rlc)
	fill_rect(b.x + b.width - r, b.y + r, r, b.height - 2 * r, rlc)
	// y grows downward: 0° is +x, 90° is +y.
	fill_corner(b.x + r, b.y + r, r, 180, 270, rlc)
	fill_corner(b.x + b.width - r, b.y + r, r, 270, 360, rlc)
	fill_corner(b.x + b.width - r, b.y + b.height - r, r, 0, 90, rlc)
	fill_corner(b.x + r, b.y + b.height - r, r, 90, 180, rlc)
}

@(private)
draw_border :: proc(b: clay.BoundingBox, config: clay.BorderRenderData, col: Color) {
	if col[3] <= 0 {
		return
	}
	rlc := to_rl_color(col)
	w := config.width
	// Like fills: no corner bigger than half the box, or the rings cross.
	config := config
	lim := min(b.width, b.height) * 0.5
	config.cornerRadius = {min(config.cornerRadius.topLeft, lim), min(config.cornerRadius.topRight, lim), min(config.cornerRadius.bottomLeft, lim), min(config.cornerRadius.bottomRight, lim)}
	if w.left > 0 {
		fill_rect(b.x, b.y + config.cornerRadius.topLeft, f32(w.left), b.height - config.cornerRadius.topLeft - config.cornerRadius.bottomLeft, rlc)
	}
	if w.right > 0 {
		fill_rect(b.x + b.width - f32(w.right), b.y + config.cornerRadius.topRight, f32(w.right), b.height - config.cornerRadius.topRight - config.cornerRadius.bottomRight, rlc)
	}
	if w.top > 0 {
		fill_rect(b.x + config.cornerRadius.topLeft, b.y, b.width - config.cornerRadius.topLeft - config.cornerRadius.topRight, f32(w.top), rlc)
	}
	if w.bottom > 0 {
		fill_rect(b.x + config.cornerRadius.bottomLeft, b.y + b.height - f32(w.bottom), b.width - config.cornerRadius.bottomLeft - config.cornerRadius.bottomRight, f32(w.bottom), rlc)
	}
	draw_corner_ring(b.x + config.cornerRadius.topLeft, b.y + config.cornerRadius.topLeft, config.cornerRadius.topLeft, f32(w.top), 180, 270, rlc)
	draw_corner_ring(b.x + b.width - config.cornerRadius.topRight, b.y + config.cornerRadius.topRight, config.cornerRadius.topRight, f32(w.top), 270, 360, rlc)
	draw_corner_ring(b.x + config.cornerRadius.bottomLeft, b.y + b.height - config.cornerRadius.bottomLeft, config.cornerRadius.bottomLeft, f32(w.bottom), 90, 180, rlc)
	draw_corner_ring(b.x + b.width - config.cornerRadius.bottomRight, b.y + b.height - config.cornerRadius.bottomRight, config.cornerRadius.bottomRight, f32(w.bottom), 0, 90, rlc)
}

@(private)
draw_corner_ring :: proc(cx, cy, radius, thick, start, end: f32, col: rl.Color) {
	if radius <= 0 || thick <= 0 {
		return
	}
	inner := math.max(0, radius - thick)
	rl.DrawRing({math.round(cx), math.round(cy)}, inner, radius, start, end, 16, col)
}
