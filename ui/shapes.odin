package ui

import "core:fmt"
import "core:math"
import rl "../deps/raylib"
import rlgl "../deps/raylib/rlgl"

// Everything the UI draws goes through two small pipelines in one stream,
// one quad per thing.
//
//   Shapes  the fragment shader works out per pixel how far it is from the
//           edge: a rounded box (each corner its own radius, a border as the
//           edge of an inner box), a triangle, or a line. Coverage ramps over
//           one physical pixel, so edges are smooth at any zoom with no
//           multisampling, and a corner costs nothing extra.
//   Glyphs  textured quads, text and images: a texel times a color.
//
// A frame's quads collect in two lists, with a draw range wherever the
// pipeline, the clip or the texture changes, and go to the GPU in one upload
// each when the frame ends: a handful of draw calls, however the UI mixes
// text and shapes. Interleaving with raylib's own batch cost a buffer upload
// per switch, and macOS's GL stalls on each one. Glyphs, most of the quads,
// carry only 36 bytes and the shapes' shader never sees them.
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
}

// One shape instance.
@(private)
Shape :: struct {
	quad:   [4]f32, // area the quad covers: x, y, w, h
	geom:   [4]f32, // Box: the box. Triangle: a, b. Segment: a, b.
	radii:  [4]f32, // Box: corner radii tl, tr, br, bl. Triangle: c. Segment: half width.
	inset:  [4]f32, // Box: border widths l, t, r, b, all 0 for a fill
	color0: [4]u8,  // at the quad's left edge
	color1: [4]u8,  // at its right edge
	kind:   f32,
	_:      f32,
}

// One glyph (or image) instance.
@(private)
Glyph :: struct {
	quad:  [4]f32, // x, y, w, h
	uv:    [4]f32, // the texture rect, 0..1
	color: [4]u8,
}

@(private)
SHAPE_VS :: `#version 330
layout(location = 0) in vec2 corner;
layout(location = 1) in vec4 i_quad;
layout(location = 2) in vec4 i_geom;
layout(location = 3) in vec4 i_radii;
layout(location = 4) in vec4 i_inset;
layout(location = 5) in vec4 i_color0;
layout(location = 6) in vec4 i_color1;
layout(location = 7) in float i_kind;
uniform vec2 u_view;
out vec2 v_p;
out vec4 v_color;
flat out vec4 v_geom;
flat out vec4 v_radii;
flat out vec4 v_inset;
flat out int v_kind;
void main() {
	v_p = i_quad.xy + corner * i_quad.zw;
	// Linear across the quad: a gradient interpolates exactly per vertex.
	v_color = mix(i_color0, i_color1, corner.x);
	v_geom = i_geom;
	v_radii = i_radii;
	v_inset = i_inset;
	v_kind = int(i_kind + 0.5);
	gl_Position = vec4(v_p.x / u_view.x * 2.0 - 1.0, 1.0 - v_p.y / u_view.y * 2.0, 0.0, 1.0);
}
`

@(private)
SHAPE_FS :: `#version 330
in vec2 v_p;
in vec4 v_color;
flat in vec4 v_geom;
flat in vec4 v_radii;
flat in vec4 v_inset;
flat in int v_kind;
uniform float u_px;
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
	float a;
	if (v_kind == 0) {
		a = cover(sd_box(v_p, v_geom, v_radii));
		if (any(greaterThan(v_inset, vec4(0.0)))) {
			// A border: take away the box inside it. Its corners keep the
			// outer curve, less the thicker of the two sides they join.
			vec4 inner = vec4(v_geom.xy + v_inset.xy, v_geom.zw - v_inset.xy - v_inset.zw);
			if (inner.z > 0.0 && inner.w > 0.0) {
				vec4 side = vec4(max(v_inset.x, v_inset.y), max(v_inset.z, v_inset.y), max(v_inset.z, v_inset.w), max(v_inset.x, v_inset.w));
				a *= 1.0 - cover(sd_box(v_p, inner, max(v_radii - side, 0.0)));
			}
		}
	} else if (v_kind == 1) {
		a = cover(sd_triangle(v_p, v_geom.xy, v_geom.zw, v_radii.xy));
	} else {
		a = cover(sd_segment(v_p, v_geom.xy, v_geom.zw) - v_radii.x);
	}
	frag = vec4(v_color.rgb, v_color.a * a);
}
`

@(private)
GLYPH_VS :: `#version 330
layout(location = 0) in vec2 corner;
layout(location = 1) in vec4 i_quad;
layout(location = 2) in vec4 i_uv;
layout(location = 3) in vec4 i_color;
uniform vec2 u_view;
out vec2 v_uv;
out vec4 v_color;
void main() {
	vec2 p = i_quad.xy + corner * i_quad.zw;
	v_uv = i_uv.xy + corner * i_uv.zw;
	v_color = i_color;
	gl_Position = vec4(p.x / u_view.x * 2.0 - 1.0, 1.0 - p.y / u_view.y * 2.0, 0.0, 1.0);
}
`

@(private)
GLYPH_FS :: `#version 330
in vec2 v_uv;
in vec4 v_color;
uniform sampler2D u_tex;
out vec4 frag;
void main() {
	frag = v_color * texture(u_tex, v_uv);
}
`

// Quads in one frame's buffer per pipeline; more is a second upload into
// the same buffer.
@(private)
QUADS_PER_FRAME :: 32768

// Frames in flight: each frame writes the next buffer, never one the GPU may
// still be reading.
@(private)
SHAPE_BUFFERS :: 3

@(private)
Pipeline :: enum u8 {
	Shapes,
	Glyphs,
}

// A run of quads with one pipeline, clip and texture.
@(private)
Draw_Range :: struct {
	pipe:         Pipeline,
	first, count: int, // in that pipeline's list
	tex:          u32,
	clip:         Maybe(Region_Box),
}

// One pipeline's GPU side.
@(private)
Pipe :: struct {
	shader:  rl.Shader,
	loc_view: i32,
	loc_px:  i32,
	vao:     u32,
	buffers: [SHAPE_BUFFERS]u32,
	written: int, // quads already in this frame's buffer
	stride:  int,
}

@(private)
s_sh: struct {
	pipes:   [Pipeline]Pipe,
	corners: u32,
	frame:   int, // picks the buffers
	shapes:  [dynamic]Shape, // not yet drawn
	glyphs:  [dynamic]Glyph,
	ranges:  [dynamic]Draw_Range,
	clip:    Maybe(Region_Box), // in effect for new quads
	overlay: Maybe(Color),      // multiplies new quads' colors (Clay's fades)
	ok:      bool,
}

@(private)
GL_UNSIGNED_BYTE :: 0x1401

@(private)
shapes_setup :: proc() {
	corners := [6][2]f32{{0, 0}, {0, 1}, {1, 0}, {1, 0}, {0, 1}, {1, 1}}
	ok := pipe_setup(&s_sh.pipes[.Shapes], SHAPE_VS, SHAPE_FS, size_of(Shape), 7, &corners)
	ok &&= pipe_setup(&s_sh.pipes[.Glyphs], GLYPH_VS, GLYPH_FS, size_of(Glyph), 3, &corners)
	if !ok {
		fmt.eprintln("ui: a UI shader did not compile; the UI will not draw")
		return
	}
	reserve(&s_sh.shapes, 1024)
	reserve(&s_sh.glyphs, 4096)
	reserve(&s_sh.ranges, 64)
	s_sh.ok = true
}

// A program, a VAO with the unit quad at location 0, and the instance
// buffers. Attribute pointers are set per draw range (point_instances).
@(private)
pipe_setup :: proc(p: ^Pipe, vs, fs: cstring, stride: int, attributes: u32, corners: ^[6][2]f32) -> bool {
	// raylib's loader, which falls back to its default shader on an error:
	// the check below.
	p.shader = rl.LoadShaderFromMemory(vs, fs)
	if p.shader.id == 0 || p.shader.id == rlgl.GetShaderIdDefault() {
		return false
	}
	p.loc_view = rl.GetShaderLocation(p.shader, "u_view")
	p.loc_px = rl.GetShaderLocation(p.shader, "u_px")
	p.stride = stride
	p.vao = rlgl.LoadVertexArray()
	rlgl.EnableVertexArray(p.vao)
	if s_sh.corners == 0 {
		s_sh.corners = rlgl.LoadVertexBuffer(corners, size_of(corners^), false)
	}
	rlgl.EnableVertexBuffer(s_sh.corners)
	rlgl.SetVertexAttribute(0, 2, rlgl.FLOAT, false, 0, 0)
	rlgl.EnableVertexAttribute(0)
	for &b in p.buffers {
		b = rlgl.LoadVertexBuffer(nil, i32(QUADS_PER_FRAME * stride), true)
	}
	for i in u32(1) ..= attributes {
		rlgl.EnableVertexAttribute(i)
		rlgl.SetVertexAttributeDivisor(i, 1)
	}
	rlgl.DisableVertexArray()
	return true
}

@(private)
shapes_teardown :: proc() {
	for &p in s_sh.pipes {
		if p.vao != 0 {
			for b in p.buffers {
				rlgl.UnloadVertexBuffer(b)
			}
			rlgl.UnloadVertexArray(p.vao)
			rl.UnloadShader(p.shader)
		}
	}
	if s_sh.corners != 0 {
		rlgl.UnloadVertexBuffer(s_sh.corners)
	}
	delete(s_sh.shapes)
	delete(s_sh.glyphs)
	delete(s_sh.ranges)
	s_sh = {}
}

// Instance attributes of `pipe` read its buffer from quad `first` on.
@(private)
point_instances :: proc(pipe: Pipeline, buffer: u32, first: int) {
	p := &s_sh.pipes[pipe]
	rlgl.EnableVertexBuffer(buffer)
	stride := i32(p.stride)
	base := i32(first) * stride
	switch pipe {
	case .Shapes:
		rlgl.SetVertexAttribute(1, 4, rlgl.FLOAT, false, stride, base + i32(offset_of(Shape, quad)))
		rlgl.SetVertexAttribute(2, 4, rlgl.FLOAT, false, stride, base + i32(offset_of(Shape, geom)))
		rlgl.SetVertexAttribute(3, 4, rlgl.FLOAT, false, stride, base + i32(offset_of(Shape, radii)))
		rlgl.SetVertexAttribute(4, 4, rlgl.FLOAT, false, stride, base + i32(offset_of(Shape, inset)))
		rlgl.SetVertexAttribute(5, 4, GL_UNSIGNED_BYTE, true, stride, base + i32(offset_of(Shape, color0)))
		rlgl.SetVertexAttribute(6, 4, GL_UNSIGNED_BYTE, true, stride, base + i32(offset_of(Shape, color1)))
		rlgl.SetVertexAttribute(7, 1, rlgl.FLOAT, false, stride, base + i32(offset_of(Shape, kind)))
	case .Glyphs:
		rlgl.SetVertexAttribute(1, 4, rlgl.FLOAT, false, stride, base + i32(offset_of(Glyph, quad)))
		rlgl.SetVertexAttribute(2, 4, rlgl.FLOAT, false, stride, base + i32(offset_of(Glyph, uv)))
		rlgl.SetVertexAttribute(3, 4, GL_UNSIGNED_BYTE, true, stride, base + i32(offset_of(Glyph, color)))
	}
}

@(private)
shapes_frame_begin :: proc() {
	s_sh.frame = (s_sh.frame + 1) % SHAPE_BUFFERS
	for &p in s_sh.pipes {
		p.written = 0
	}
	s_sh.clip = nil
	clear(&s_sh.shapes)
	clear(&s_sh.glyphs)
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

// Upload one pipeline's pending quads; where they start in its buffer.
@(private)
upload :: proc(pipe: Pipeline, data: rawptr, n: int) -> (buffer: u32, base: int) {
	p := &s_sh.pipes[pipe]
	buffer = p.buffers[s_sh.frame]
	if n == 0 {
		return
	}
	if p.written + n > QUADS_PER_FRAME {
		p.written = 0 // overflowing a frame: reuse it, at the cost of a stall
	}
	rlgl.UpdateVertexBuffer(buffer, data, i32(n * p.stride), i32(p.written * p.stride))
	base = p.written
	p.written += n
	return
}

// Draw everything queued. The ui calls this itself at the end of the frame.
// A host calls it before drawing with raylib after ui.draw_* calls (or in a
// Custom_Draw), so the two land in order.
flush_shapes :: proc() {
	if len(s_sh.ranges) == 0 || !s_sh.ok {
		clear(&s_sh.shapes)
		clear(&s_sh.glyphs)
		clear(&s_sh.ranges)
		return
	}
	ns := min(len(s_sh.shapes), QUADS_PER_FRAME)
	ng := min(len(s_sh.glyphs), QUADS_PER_FRAME)
	buffers: [Pipeline]u32
	bases: [Pipeline]int
	buffers[.Shapes], bases[.Shapes] = upload(.Shapes, raw_data(s_sh.shapes), ns)
	buffers[.Glyphs], bases[.Glyphs] = upload(.Glyphs, raw_data(s_sh.glyphs), ng)
	limit := [Pipeline]int{.Shapes = ns, .Glyphs = ng}

	view := [2]f32{screen_w, screen_h}
	px := 1 / raster_scale()
	rlgl.DisableBackfaceCulling()
	rlgl.ActiveTextureSlot(0)
	bound: Maybe(Pipeline)
	for r in s_sh.ranges {
		if r.first >= limit[r.pipe] {
			continue
		}
		if bound != r.pipe {
			p := &s_sh.pipes[r.pipe]
			rlgl.EnableShader(p.shader.id)
			rlgl.SetUniform(p.loc_view, &view, i32(rl.ShaderUniformDataType.VEC2), 1)
			if p.loc_px >= 0 {
				rlgl.SetUniform(p.loc_px, &px, i32(rl.ShaderUniformDataType.FLOAT), 1)
			}
			rlgl.EnableVertexArray(p.vao)
			bound = r.pipe
		}
		gl_clip(r.clip)
		if r.pipe == .Glyphs {
			rlgl.EnableTexture(r.tex)
		}
		point_instances(r.pipe, buffers[r.pipe], bases[r.pipe] + r.first)
		rlgl.DrawVertexArrayInstanced(0, 6, i32(min(r.count, limit[r.pipe] - r.first)))
	}
	rlgl.DisableTexture()
	rlgl.EnableBackfaceCulling()
	rlgl.DisableVertexArray()
	rlgl.DisableShader()
	gl_clip(s_sh.clip)

	clear(&s_sh.shapes)
	clear(&s_sh.glyphs)
	clear(&s_sh.ranges)
}

// The range new quads of `pipe` join, a new one when the pipeline, clip or
// texture differs from the last.
@(private)
join_range :: proc(pipe: Pipeline, first: int, tex: u32) {
	if len(s_sh.shapes) == 0 && len(s_sh.glyphs) == 0 {
		// Whatever raylib has queued was drawn first, so it goes first.
		rlgl.DrawRenderBatchActive()
	}
	if len(s_sh.ranges) > 0 {
		last := &s_sh.ranges[len(s_sh.ranges) - 1]
		if last.pipe == pipe && last.clip == s_sh.clip && last.tex == tex {
			last.count += 1
			return
		}
	}
	append(&s_sh.ranges, Draw_Range{pipe = pipe, first = first, count = 1, tex = tex, clip = s_sh.clip})
}

@(private)
push_shape :: proc(s: Shape) {
	s := s
	if o, ok := s_sh.overlay.?; ok {
		s.color0 = rgba8(fade(color_of(s.color0), o))
		s.color1 = rgba8(fade(color_of(s.color1), o))
	}
	join_range(.Shapes, len(s_sh.shapes), 0)
	append(&s_sh.shapes, s)
	if len(s_sh.shapes) >= QUADS_PER_FRAME {
		flush_shapes()
	}
}

// A textured quad: `src` in texels of `tex`, drawn at `dst`, tinted.
@(private)
push_texture :: proc(tex: rl.Texture2D, src: rl.Rectangle, dst: Region_Box, tint: Color) {
	tint := tint
	if o, ok := s_sh.overlay.?; ok {
		tint = fade(tint, o)
	}
	if tex.id == 0 || tex.width == 0 || tex.height == 0 || tint.a <= 0 {
		return
	}
	tw, th := f32(tex.width), f32(tex.height)
	join_range(.Glyphs, len(s_sh.glyphs), tex.id)
	append(&s_sh.glyphs, Glyph{
		quad  = {dst.x, dst.y, dst.width, dst.height},
		uv    = {src.x / tw, src.y / th, src.width / tw, src.height / th},
		color = rgba8(tint),
	})
	if len(s_sh.glyphs) >= QUADS_PER_FRAME {
		flush_shapes()
	}
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

// A color times an overlay, channel by channel: how Clay's overlay fades work here (Clay's
// docs describe a mix; multiplying by white at an alpha is the fade).
@(private)
fade :: proc(c, overlay: Color) -> Color {
	return c * overlay / 255
}

@(private)
color_of :: proc(c: [4]u8) -> Color {
	return {f32(c.r), f32(c.g), f32(c.b), f32(c.a)}
}

@(private)
rgba8 :: proc(c: Color) -> [4]u8 {
	return {u8(clamp(c.r + 0.5, 0, 255)), u8(clamp(c.g + 0.5, 0, 255)), u8(clamp(c.b + 0.5, 0, 255)), u8(clamp(c.a + 0.5, 0, 255))}
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
		geom   = {b.x, b.y, b.width, b.height},
		radii  = {max(r.x, 0), max(r.y, 0), max(r.z, 0), max(r.w, 0)},
		inset  = inset,
		color0 = rgba8(c0),
		color1 = rgba8(c1),
		kind   = f32(Shape_Kind.Box),
	})
}

// Round a layout-space coordinate onto the physical pixel grid.
snap_px :: proc(v: f32) -> f32 {
	s := raster_scale()
	return math.round(v * s) / s
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
	col := rgba8(color)
	push_shape({
		quad   = {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y},
		geom   = {a.x, a.y, b.x, b.y},
		radii  = {c.x, c.y, 0, 0},
		color0 = col,
		color1 = col,
		kind   = f32(Shape_Kind.Triangle),
	})
}

// A line `width` thick with round ends.
draw_line :: proc(a, b: [2]f32, width: f32, color: Color) {
	h := width * 0.5
	px := 1 / raster_scale()
	lo := [2]f32{min(a.x, b.x), min(a.y, b.y)} - h - px
	hi := [2]f32{max(a.x, b.x), max(a.y, b.y)} + h + px
	col := rgba8(color)
	push_shape({
		quad   = {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y},
		geom   = {a.x, a.y, b.x, b.y},
		radii  = {h, 0, 0, 0},
		color0 = col,
		color1 = col,
		kind   = f32(Shape_Kind.Segment),
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
		c := rgba8(stops[0] if i == 0 else stops[len(stops) - 1])
		push_shape({
			quad   = {e[0], b.y - px, e[1] - e[0], b.height + 2 * px},
			geom   = {b.x, b.y, b.width, b.height},
			radii  = {r, r, r, r},
			color0 = c,
			color1 = c,
		})
	}
	for i in 0 ..< len(stops) - 1 {
		push_shape({
			quad   = {x0 + seg * f32(i), b.y - px, seg, b.height + 2 * px},
			geom   = {b.x, b.y, b.width, b.height},
			radii  = {r, r, r, r},
			color0 = rgba8(stops[i]),
			color1 = rgba8(stops[i + 1]),
		})
	}
}
