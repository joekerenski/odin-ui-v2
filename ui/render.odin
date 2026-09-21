package ui

import clay "../deps/clay"
import "core:math"
import "core:strings"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// Clay render commands to raylib. Text quads are snapped onto the physical
// pixel grid. Filled rects use raylib's rounded-rect path (uniform corners,
// 16 segments). Per-side borders are rects plus rings.

to_rl_color :: proc(color: Color) -> rl.Color {
	return {u8(color[0]), u8(color[1]), u8(color[2]), u8(color[3])}
}

draw_circle :: proc(x, y, r: f32, color: Color) {
	rl.DrawCircleV({x, y}, r, to_rl_color(color))
}

draw_triangle :: proc(a, b, c: [2]f32, color: Color) {
	rl.DrawTriangle({a.x, a.y}, {b.x, b.y}, {c.x, c.y}, to_rl_color(color))
}

@(private)
snap_px :: proc(v: f32) -> f32 {
	s := dpi_scale()
	return math.round(v * s) / s
}

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

render :: proc(commands: ^clay.ClayArray(clay.RenderCommand), allocator := context.temp_allocator) {
	overlay := make([dynamic]Color, allocator)
	for i in 0 ..< commands.length {
		cmd := clay.RenderCommandArray_Get(commands, i32(i))
		b := cmd.boundingBox
		switch cmd.commandType {
		case .None:
		case .Text:
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
				f32(config.fontSize),
				f32(config.letterSpacing),
				to_rl_color(apply_overlay(config.textColor, overlay)),
			)
		case .Image:
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
			rl.BeginScissorMode(
				i32(math.round(b.x)),
				i32(math.round(b.y)),
				i32(math.round(b.width)),
				i32(math.round(b.height)),
			)
		case .ScissorEnd:
			rl.EndScissorMode()
		case .Rectangle:
			config := cmd.renderData.rectangle
			draw_round_rect(b, config.cornerRadius, apply_overlay(config.backgroundColor, overlay))
		case .Border:
			config := cmd.renderData.border
			draw_border(b, config, apply_overlay(config.color, overlay))
		case .OverlayColorStart:
			append(&overlay, cmd.renderData.overlayColor.color)
		case .OverlayColorEnd:
			if len(overlay) > 0 {
				pop(&overlay)
			}
		case .Custom:
			dispatch_custom(cmd)
		}
	}
}

// DrawRectangle emits GL quads, which this 4.1 context does not rasterize.
// Triangles do, but only if they sample the white shapes texel — an unset
// texcoord reads the font atlas and the fill disappears.
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
