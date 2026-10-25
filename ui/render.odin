package ui

import clay "../deps/clay"
import rl "../deps/raylib"

// Clay render commands to the screen, through the stream in shapes.odin:
// rectangles and borders are shapes with their edges on the physical pixel
// grid, text and images are glyph quads. Clips and overlays (fades) are the
// stream's state, so Custom elements get them too.

// Clip boxes nest: each is intersected with its parent, and closing one
// restores the parent. A clip is the stream's state for the quads after it;
// GL's scissor is set when they're drawn. So the many clips Clay brackets
// floating elements in (each slider knob, each segment label), mostly the
// same box again, cost nothing unless what they hold draws.
render :: proc(commands: ^clay.ClayArray(clay.RenderCommand), allocator := context.temp_allocator) {
	overlay := make([dynamic]Color, allocator)
	clips := make([dynamic]clay.BoundingBox, allocator)
	defer s_sh.overlay = nil
	defer s_sh.clip = nil
	for i in 0 ..< commands.length {
		cmd := clay.RenderCommandArray_Get(commands, i32(i))
		b := cmd.boundingBox
		switch cmd.commandType {
		case .None:
		case .Text:
			config := cmd.renderData.text
			t := string(config.stringContents.chars[:config.stringContents.length])
			draw_text(t, b.x, b.y, config.fontId, config.fontSize, config.textColor, f32(config.letterSpacing))
		case .Image:
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
			s_sh.clip = r
		case .ScissorEnd:
			if len(clips) > 0 {
				pop(&clips)
			}
			s_sh.clip = clips[len(clips) - 1] if len(clips) > 0 else nil
		case .Rectangle:
			config := cmd.renderData.rectangle
			draw_round_rect(b, config.cornerRadius, config.backgroundColor)
		case .Border:
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
