package ui

import clay "../deps/clay"
import "core:math"
import rl "../deps/raylib"

// Clay render commands to the screen. Rectangles and borders are shapes
// (shapes.odin): one quad each, edges on the physical pixel grid, corners
// from the shader. Text and images go through raylib's batch.

to_rl_color :: proc(color: Color) -> rl.Color {
	return {u8(color[0]), u8(color[1]), u8(color[2]), u8(color[3])}
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

// Clips go into the shape stream, which sets them on GL when it draws.
@(private)
set_scissor :: proc(b: clay.BoundingBox) {
	shapes_clip(b)
}

@(private)
end_scissor :: proc() {
	shapes_clip(nil)
}

// Clip boxes nest: each is intersected with its parent, and closing one
// restores the parent instead of turning clipping off.
//
// Every clipped floating element (each slider knob, each segment label) is
// its own Clay root, bracketed in its own scissor start and end, mostly with
// the same box as the one before. So the clip is only set when something
// draws, and only when it differs from the one in effect: fewer draw ranges.
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
			end_scissor()
		}
	}
	defer if active != nil {
		end_scissor()
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
			draw_text(t, b.x, b.y, config.fontId, config.fontSize, apply_overlay(config.textColor, overlay), f32(config.letterSpacing))
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
			// Scaled to the box's width, as raylib's DrawTextureEx did.
			h := f32(tex.height) * b.width / f32(tex.width)
			push_texture(tex^, {0, 0, f32(tex.width), f32(tex.height)}, {b.x, b.y, b.width, h}, tint)
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

// A Clay rectangle: a box on the pixel grid.
@(private)
draw_round_rect :: proc(b: clay.BoundingBox, rad: clay.CornerRadius, col: Color) {
	if col[3] <= 0 {
		return
	}
	push_box(snap_box(b), {rad.topLeft, rad.topRight, rad.bottomRight, rad.bottomLeft}, col, col)
}

// A Clay border: the box less the box inside its widths, each a whole pixel.
@(private)
draw_border :: proc(b: clay.BoundingBox, config: clay.BorderRenderData, col: Color) {
	if col[3] <= 0 {
		return
	}
	w := config.width
	inset := [4]f32{snap_width(f32(w.left)), snap_width(f32(w.top)), snap_width(f32(w.right)), snap_width(f32(w.bottom))}
	if inset == {} {
		return
	}
	r := config.cornerRadius
	push_box(snap_box(b), {r.topLeft, r.topRight, r.bottomRight, r.bottomLeft}, col, col, inset)
}
