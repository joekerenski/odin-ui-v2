package ui

import clay "../deps/clay"
import "core:math"
import rl "../deps/raylib"

// Clay render commands to the screen, through the stream in shapes.odin:
// rectangles and borders are shapes with their edges on the physical pixel
// grid, text and images are glyph quads. Clips and overlays (fades) are the
// stream's state, so Custom elements get them too.

to_rl_color :: proc(color: Color) -> rl.Color {
	return {u8(color[0]), u8(color[1]), u8(color[2]), u8(color[3])}
}

// Round a layout-space coordinate onto the physical pixel grid.
snap_px :: proc(v: f32) -> f32 {
	s := raster_scale()
	return math.round(v * s) / s
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
	defer s_sh.overlay = nil
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
			draw_text(t, b.x, b.y, config.fontId, config.fontSize, config.textColor, f32(config.letterSpacing))
		case .Image:
			sync(&active, clips)
			tex := (^rl.Texture2D)(cmd.renderData.image.imageData)
			if tex == nil || tex.width == 0 {
				continue
			}
			// Scaled to the box's width, keeping the image's shape.
			h := f32(tex.height) * b.width / f32(tex.width)
			push_texture(tex^, {0, 0, f32(tex.width), f32(tex.height)}, {b.x, b.y, b.width, h}, {255, 255, 255, 255})
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
			draw_round_rect(b, config.cornerRadius, config.backgroundColor)
		case .Border:
			sync(&active, clips)
			config := cmd.renderData.border
			draw_border(b, config, config.color)
		case .OverlayColorStart:
			// Each overlay is multiplied into its parents, so the top is the whole effect.
			c := cmd.renderData.overlayColor.color
			if len(overlay) > 0 {
				c = fade(c, overlay[len(overlay) - 1])
			}
			append(&overlay, c)
			s_sh.overlay = c
		case .OverlayColorEnd:
			if len(overlay) > 0 {
				pop(&overlay)
			}
			s_sh.overlay = overlay[len(overlay) - 1] if len(overlay) > 0 else nil
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
