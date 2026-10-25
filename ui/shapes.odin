package ui

import "core:fmt"
import "core:math"
import rl "../deps/raylib"
import rlgl "../deps/raylib/rlgl"

// Everything the UI draws goes through one shader, one quad per thing. For
// a shape, the fragment shader works out per pixel how far it is from the
// edge: a rounded box (each corner its own radius, a border as the edge of
// an inner box), a triangle, or a line. Coverage ramps over one physical
// pixel, so edges are smooth at any zoom with no multisampling, and a corner
// costs nothing extra. Text glyphs and images are textured quads in the same
// stream.
//
// A frame's quads collect in one list, with a draw range wherever the clip
// or the texture changes, and go to the GPU in one upload when the frame
// ends: a handful of draw calls, however the UI mixes text and shapes. A
// stream that alternated with raylib's own batch cost a buffer upload per
// switch, and macOS's GL stalls on each one.
//
// raylib's batch (whatever a host draws with rl.*) is still separate. The
// first quad after raylib drawing flushes raylib's batch, so that goes
// first. The other way round, a host calls flush_shapes() before drawing
// with rl.* after ui.draw_* calls, or those land on top.
//
// Everything is in layout units, the space the UI lays out in.

@(private)
Shape_Kind :: enum u8 {
	Box,
	Triangle,
	Segment,
	Texture, // `box` is the texture rect, 0..1; the texel times color0
}

// One instance. Every field is a vec4, which keeps the vertex layout plain.
@(private)
Shape :: struct {
	quad:   [4]f32, // area the quad covers: x, y, w, h
	box:    [4]f32, // Box: the box. Texture: the texture rect, 0..1.
	radii:  [4]f32, // Box: corner radii tl, tr, br, bl. Triangle: a, b. Segment: a, b.
	inset:  [4]f32, // Box: border widths l, t, r, b, all 0 for a fill. Triangle: c. Segment: half width.
	color0: [4]f32, // 0..1, at the quad's left edge
	color1: [4]f32, // at its right edge
	extra:  [4]f32, // kind
}

@(private)
SHAPE_VS :: `#version 330
layout(location = 0) in vec2 corner;
layout(location = 1) in vec4 i_quad;
layout(location = 2) in vec4 i_box;
layout(location = 3) in vec4 i_radii;
layout(location = 4) in vec4 i_inset;
layout(location = 5) in vec4 i_color0;
layout(location = 6) in vec4 i_color1;
layout(location = 7) in vec4 i_extra;
uniform vec2 u_view;
out vec2 v_p;
flat out vec4 v_quad;
flat out vec4 v_box;
flat out vec4 v_radii;
flat out vec4 v_inset;
flat out vec4 v_color0;
flat out vec4 v_color1;
flat out vec4 v_extra;
void main() {
	v_p = i_quad.xy + corner * i_quad.zw;
	v_quad = i_quad;
	v_box = i_box;
	v_radii = i_radii;
	v_inset = i_inset;
	v_color0 = i_color0;
	v_color1 = i_color1;
	v_extra = i_extra;
	gl_Position = vec4(v_p.x / u_view.x * 2.0 - 1.0, 1.0 - v_p.y / u_view.y * 2.0, 0.0, 1.0);
}
`

@(private)
SHAPE_FS :: `#version 330
in vec2 v_p;
flat in vec4 v_quad;
flat in vec4 v_box;
flat in vec4 v_radii;
flat in vec4 v_inset;
flat in vec4 v_color0;
flat in vec4 v_color1;
flat in vec4 v_extra;
uniform float u_px;
uniform sampler2D u_tex;
out vec4 frag;

// Signed distance to a box with a radius per corner (tl, tr, br, bl; y down).
float sd_box(vec2 p, vec4 b, vec4 r) {
	vec2 h = b.zw * 0.5;
	vec2 q = p - (b.xy + h);
	float rr = q.x < 0.0 ? (q.y < 0.0 ? r.x : r.w) : (q.y < 0.0 ? r.y : r.z);
	vec2 d = abs(q) - h + rr;
	return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - rr;
}

float sd_segment(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-8), 0.0, 1.0);
	return length(pa - ba * h);
}

// Inigo Quilez's exact triangle distance.
float sd_triangle(vec2 p, vec2 p0, vec2 p1, vec2 p2) {
	vec2 e0 = p1 - p0, e1 = p2 - p1, e2 = p0 - p2;
	vec2 v0 = p - p0, v1 = p - p1, v2 = p - p2;
	vec2 pq0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0, 1.0);
	vec2 pq1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0, 1.0);
	vec2 pq2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0, 1.0);
	float s = sign(e0.x * e2.y - e0.y * e2.x);
	vec2 d = min(min(vec2(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x)),
	                 vec2(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x))),
	                 vec2(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x)));
	return -sqrt(d.x) * sign(d.y);
}

// 1 inside, 0 outside, a ramp one pixel wide across the edge.
float cover(float d) {
	return clamp(0.5 - d / u_px, 0.0, 1.0);
}

void main() {
	int kind = int(v_extra.x + 0.5);
	if (kind == 3) {
		vec2 uv = v_box.xy + (v_p - v_quad.xy) / v_quad.zw * v_box.zw;
		frag = v_color0 * texture(u_tex, uv);
		if (frag.a <= 0.0) {
			discard;
		}
		return;
	}
	float a;
	if (kind == 0) {
		a = cover(sd_box(v_p, v_box, v_radii));
		if (any(greaterThan(v_inset, vec4(0.0)))) {
			// A border: take away the box inside it. Its corners keep the
			// outer curve, less the thicker of the two sides they join.
			vec4 inner = vec4(v_box.xy + v_inset.xy, v_box.zw - v_inset.xy - v_inset.zw);
			if (inner.z > 0.0 && inner.w > 0.0) {
				vec4 side = vec4(max(v_inset.x, v_inset.y), max(v_inset.z, v_inset.y), max(v_inset.z, v_inset.w), max(v_inset.x, v_inset.w));
				a *= 1.0 - cover(sd_box(v_p, inner, max(v_radii - side, 0.0)));
			}
		}
	} else if (kind == 1) {
		a = cover(sd_triangle(v_p, v_radii.xy, v_radii.zw, v_inset.xy));
	} else {
		a = cover(sd_segment(v_p, v_radii.xy, v_radii.zw) - v_inset.x);
	}
	float t = clamp((v_p.x - v_quad.x) / max(v_quad.z, 1e-4), 0.0, 1.0);
	vec4 c = mix(v_color0, v_color1, t);
	if (c.a * a <= 0.0) {
		discard;
	}
	frag = vec4(c.rgb, c.a * a);
}
`

// Quads in one frame's buffer; more is a second upload into the same buffer.
@(private)
SHAPES_PER_FRAME :: 32768

// Frames in flight: each frame writes the next buffer, never one the GPU may
// still be reading.
@(private)
SHAPE_BUFFERS :: 3

// A run of quads with one clip and one texture.
@(private)
Draw_Range :: struct {
	first, count: int,
	tex:          u32, // 0: no texture yet; untextured quads fit any
	clip:         Maybe(Region_Box),
}

@(private)
s_sh: struct {
	shader:    rl.Shader,
	loc_view:  i32,
	loc_px:    i32,
	vao:       u32,
	corners:   u32,
	buffers:   [SHAPE_BUFFERS]u32,
	frame:     int, // picks the buffer
	written:   int, // quads already in this frame's buffer
	quads:     [dynamic]Shape, // not yet drawn
	ranges:    [dynamic]Draw_Range,
	clip:      Maybe(Region_Box), // in effect for new quads
	ok:        bool,
}

@(private)
shapes_setup :: proc() {
	// raylib's own loader: the vendored rlgl bindings predate raylib 6's
	// renamed shader calls (rlLoadShaderCode is gone from the library).
	s_sh.shader = rl.LoadShaderFromMemory(SHAPE_VS, SHAPE_FS)
	if s_sh.shader.id == 0 || s_sh.shader.id == rlgl.GetShaderIdDefault() {
		fmt.eprintln("ui: the shape shader did not compile; the UI will not draw")
		return
	}
	s_sh.loc_view = rl.GetShaderLocation(s_sh.shader, "u_view")
	s_sh.loc_px = rl.GetShaderLocation(s_sh.shader, "u_px")

	s_sh.vao = rlgl.LoadVertexArray()
	rlgl.EnableVertexArray(s_sh.vao)
	corners := [6][2]f32{{0, 0}, {0, 1}, {1, 0}, {1, 0}, {0, 1}, {1, 1}}
	s_sh.corners = rlgl.LoadVertexBuffer(&corners, size_of(corners), false)
	rlgl.SetVertexAttribute(0, 2, rlgl.FLOAT, false, 0, 0)
	rlgl.EnableVertexAttribute(0)
	for &b in s_sh.buffers {
		b = rlgl.LoadVertexBuffer(nil, SHAPES_PER_FRAME * size_of(Shape), true)
	}
	for i in u32(1) ..= 7 {
		rlgl.EnableVertexAttribute(i)
		rlgl.SetVertexAttributeDivisor(i, 1)
	}
	point_instances(s_sh.buffers[0], 0)
	rlgl.DisableVertexArray()
	reserve(&s_sh.quads, 4096)
	reserve(&s_sh.ranges, 64)
	s_sh.ok = true
}

@(private)
shapes_teardown :: proc() {
	if s_sh.ok {
		rlgl.UnloadVertexBuffer(s_sh.corners)
		for b in s_sh.buffers {
			rlgl.UnloadVertexBuffer(b)
		}
		rlgl.UnloadVertexArray(s_sh.vao)
		rl.UnloadShader(s_sh.shader)
	}
	delete(s_sh.quads)
	delete(s_sh.ranges)
	s_sh = {}
}

// Instance attributes read `buffer` from quad `first` on.
@(private)
point_instances :: proc(buffer: u32, first: int) {
	rlgl.EnableVertexBuffer(buffer)
	stride := i32(size_of(Shape))
	base := i32(first) * stride
	for i in u32(1) ..= 7 {
		rlgl.SetVertexAttribute(i, 4, rlgl.FLOAT, false, stride, base + i32(i - 1) * 16)
	}
}

@(private)
shapes_frame_begin :: proc() {
	s_sh.frame = (s_sh.frame + 1) % SHAPE_BUFFERS
	s_sh.written = 0
	s_sh.clip = nil
	clear(&s_sh.quads)
	clear(&s_sh.ranges)
}

// The clip for quads from here on. Also set on GL at once, for anything a
// host draws with raylib meanwhile; what raylib has queued is drawn first,
// under the clip it was drawn with.
@(private)
shapes_clip :: proc(clip: Maybe(Region_Box)) {
	if clip == s_sh.clip {
		return
	}
	rlgl.DrawRenderBatchActive()
	s_sh.clip = clip
	gl_clip(clip)
}

// Draw everything queued. The ui calls this itself at the end of the frame
// and before handing a host a Custom element to draw. A host calls it before
// drawing with raylib after ui.draw_* calls, so the two land in order.
flush_shapes :: proc() {
	n := len(s_sh.quads)
	if n == 0 || !s_sh.ok {
		clear(&s_sh.quads)
		clear(&s_sh.ranges)
		return
	}
	buffer := s_sh.buffers[s_sh.frame]
	if s_sh.written + n > SHAPES_PER_FRAME {
		s_sh.written = 0 // overflowing a frame: reuse it, at the cost of a stall
	}
	if n > SHAPES_PER_FRAME {
		n = SHAPES_PER_FRAME
	}
	stride := size_of(Shape)
	rlgl.UpdateVertexBuffer(buffer, raw_data(s_sh.quads), i32(n * stride), i32(s_sh.written * stride))

	rlgl.EnableShader(s_sh.shader.id)
	view := [2]f32{screen_w, screen_h}
	px := 1 / raster_scale()
	rlgl.SetUniform(s_sh.loc_view, &view, i32(rl.ShaderUniformDataType.VEC2), 1)
	rlgl.SetUniform(s_sh.loc_px, &px, i32(rl.ShaderUniformDataType.FLOAT), 1)
	rlgl.EnableVertexArray(s_sh.vao)
	rlgl.DisableBackfaceCulling()
	rlgl.ActiveTextureSlot(0)
	for r in s_sh.ranges {
		if r.first >= n {
			break
		}
		gl_clip(r.clip)
		rlgl.EnableTexture(r.tex if r.tex != 0 else shapes_tex.id)
		point_instances(buffer, s_sh.written + r.first)
		rlgl.DrawVertexArrayInstanced(0, 6, i32(min(r.count, n - r.first)))
	}
	rlgl.DisableTexture()
	rlgl.EnableBackfaceCulling()
	rlgl.DisableVertexArray()
	rlgl.DisableShader()
	gl_clip(s_sh.clip)

	s_sh.written += n
	clear(&s_sh.quads)
	clear(&s_sh.ranges)
}

@(private)
push_shape :: proc(s: Shape, tex: u32 = 0) {
	if len(s_sh.quads) == 0 {
		// Whatever raylib has queued was drawn first, so it goes first.
		rlgl.DrawRenderBatchActive()
	}
	last := &s_sh.ranges[len(s_sh.ranges) - 1] if len(s_sh.ranges) > 0 else nil
	if last == nil || last.clip != s_sh.clip || (tex != 0 && last.tex != 0 && last.tex != tex) {
		append(&s_sh.ranges, Draw_Range{first = len(s_sh.quads), clip = s_sh.clip})
		last = &s_sh.ranges[len(s_sh.ranges) - 1]
	}
	if tex != 0 {
		last.tex = tex
	}
	last.count += 1
	append(&s_sh.quads, s)
	if len(s_sh.quads) >= SHAPES_PER_FRAME {
		flush_shapes()
	}
}

// A textured quad: `src` in texels of `tex`, drawn at `dst`, tinted.
@(private)
push_texture :: proc(tex: rl.Texture2D, src: rl.Rectangle, dst: Region_Box, tint: Color) {
	if tex.id == 0 || tex.width == 0 || tex.height == 0 || tint.a <= 0 {
		return
	}
	tw, th := f32(tex.width), f32(tex.height)
	push_shape({
		quad   = {dst.x, dst.y, dst.width, dst.height},
		box    = {src.x / tw, src.y / th, src.width / tw, src.height / th},
		color0 = unit(tint),
		extra  = {f32(Shape_Kind.Texture), 0, 0, 0},
	}, tex.id)
}

// The GL scissor for a clip in layout units, in framebuffer pixels (y up).
@(private)
gl_clip :: proc(clip: Maybe(Region_Box)) {
	b, ok := clip.?
	if !ok {
		rlgl.DisableScissorTest()
		return
	}
	fw, fh := framebuffer_size()
	s := f32(fw) / f32(rl.GetScreenWidth()) * zoom
	x0, y0 := math.round(b.x * s), math.round(b.y * s)
	x1, y1 := math.round((b.x + b.width) * s), math.round((b.y + b.height) * s)
	rlgl.EnableScissorTest()
	rlgl.Scissor(i32(x0), fh - i32(y1), i32(max(0, x1 - x0)), i32(max(0, y1 - y0)))
}

@(private)
unit :: proc(c: Color) -> [4]f32 {
	return {c.r, c.g, c.b, c.a} / 255
}

// A box: filled, or a border when any inset is above 0. `exact` boxes are
// already on the pixel grid and cover only themselves; others reach a pixel
// further for the edge's ramp.
@(private)
push_box :: proc(b: Region_Box, radii: [4]f32, c0, c1: Color, inset: [4]f32 = {}, exact := true) {
	if b.width <= 0 || b.height <= 0 || (c0.a <= 0 && c1.a <= 0) {
		return
	}
	half := min(b.width, b.height) * 0.5
	r := [4]f32{min(radii.x, half), min(radii.y, half), min(radii.z, half), min(radii.w, half)}
	quad := [4]f32{b.x, b.y, b.width, b.height}
	if !exact {
		px := 1 / raster_scale()
		quad = {b.x - px, b.y - px, b.width + 2 * px, b.height + 2 * px}
	}
	push_shape({
		quad   = quad,
		box    = {b.x, b.y, b.width, b.height},
		radii  = {max(r.x, 0), max(r.y, 0), max(r.z, 0), max(r.w, 0)},
		inset  = inset,
		color0 = unit(c0),
		color1 = unit(c1),
		extra  = {f32(Shape_Kind.Box), 0, 0, 0},
	})
}

// A box's edges on the physical pixel grid, so fills and borders are crisp.
@(private)
snap_box :: proc(b: Region_Box) -> Region_Box {
	x0, y0 := snap_px(b.x), snap_px(b.y)
	x1, y1 := snap_px(b.x + b.width), snap_px(b.y + b.height)
	return {x0, y0, x1 - x0, y1 - y0}
}

// A border width as whole pixels, at least one.
@(private)
snap_width :: proc(w: f32) -> f32 {
	if w <= 0 {
		return 0
	}
	s := raster_scale()
	return max(1, math.round(w * s)) / s
}

// --- for hosts and widgets ----------------------------------------------------------
//
// In layout units, like everything else. They batch; see flush_shapes.

// A filled box, its corners rounded by `radius`.
draw_rect :: proc(b: Region_Box, color: Color, radius: f32 = 0) {
	push_box(b, {radius, radius, radius, radius}, color, color, exact = false)
}

// A box's outline, `width` thick, inside the box.
draw_rect_lines :: proc(b: Region_Box, width: f32, color: Color, radius: f32 = 0) {
	push_box(b, {radius, radius, radius, radius}, color, color, inset = {width, width, width, width}, exact = false)
}

draw_circle :: proc(x, y, r: f32, color: Color) {
	push_box({x - r, y - r, 2 * r, 2 * r}, {r, r, r, r}, color, color, exact = false)
}

// A circle's outline, `width` thick, inside radius `r`.
draw_ring :: proc(x, y, r, width: f32, color: Color) {
	push_box({x - r, y - r, 2 * r, 2 * r}, {r, r, r, r}, color, color, inset = {width, width, width, width}, exact = false)
}

// Any vertex order.
draw_triangle :: proc(a, b, c: [2]f32, color: Color) {
	px := 1 / raster_scale()
	lo := [2]f32{min(a.x, b.x, c.x), min(a.y, b.y, c.y)} - px
	hi := [2]f32{max(a.x, b.x, c.x), max(a.y, b.y, c.y)} + px
	col := unit(color)
	push_shape({
		quad   = {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y},
		radii  = {a.x, a.y, b.x, b.y},
		inset  = {c.x, c.y, 0, 0},
		color0 = col,
		color1 = col,
		extra  = {f32(Shape_Kind.Triangle), 0, 0, 0},
	})
}

// A line `width` thick with round ends.
draw_line :: proc(a, b: [2]f32, width: f32, color: Color) {
	h := width * 0.5
	px := 1 / raster_scale()
	lo := [2]f32{min(a.x, b.x), min(a.y, b.y)} - h - px
	hi := [2]f32{max(a.x, b.x), max(a.y, b.y)} + h + px
	col := unit(color)
	push_shape({
		quad   = {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y},
		radii  = {a.x, a.y, b.x, b.y},
		inset  = {h, 0, 0, 0},
		color0 = col,
		color1 = col,
		extra  = {f32(Shape_Kind.Segment), 0, 0, 0},
	})
}

// A pill with a horizontal gradient through `stops`, evenly spaced. Each stop
// pair is its own quad, all measuring the same pill, so no seams.
draw_gradient_pill :: proc(b: Region_Box, stops: []Color) {
	if len(stops) == 0 || b.width <= 0 || b.height <= 0 {
		return
	}
	r := min(b.width, b.height) * 0.5
	if len(stops) == 1 {
		push_box(b, {r, r, r, r}, stops[0], stops[0], exact = false)
		return
	}
	// Flat ends under the round caps; the gradient spans the straight part.
	x0, x1 := b.x + r, b.x + b.width - r
	seg := (x1 - x0) / f32(len(stops) - 1)
	px := 1 / raster_scale()
	ends := [2][2]f32{{b.x - px, x0}, {x1, b.x + b.width + px}}
	for e, i in ends {
		c := unit(stops[0] if i == 0 else stops[len(stops) - 1])
		push_shape({
			quad   = {e[0], b.y - px, e[1] - e[0], b.height + 2 * px},
			box    = {b.x, b.y, b.width, b.height},
			radii  = {r, r, r, r},
			color0 = c,
			color1 = c,
		})
	}
	for i in 0 ..< len(stops) - 1 {
		push_shape({
			quad   = {x0 + seg * f32(i), b.y - px, seg, b.height + 2 * px},
			box    = {b.x, b.y, b.width, b.height},
			radii  = {r, r, r, r},
			color0 = unit(stops[i]),
			color1 = unit(stops[i + 1]),
		})
	}
}
