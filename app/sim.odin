package main

import "core:math"
import "core:math/rand"

// A small force-directed graph. Nodes repel, edges are springs, and a weak
// pull toward the origin keeps the cloud on the canvas. Positions are in
// canvas-local space with the origin at the canvas center.

Node :: struct {
	id:       int,
	pos, vel: [2]f32,
}

Edge :: struct {
	a, b: int, // node ids
}

Graph :: struct {
	nodes:     [dynamic]Node,
	edges:     [dynamic]Edge,
	next_id:   int,
	spring:    f32,
	rest:      f32,
	repulsion: f32,
	damping:   f32,
	gravity:   f32,
	paused:    bool,
	selected:  int, // node id, or -1
	linking:   bool,
}

NODE_R :: f32(16)
SOFT :: f32(36)

boot :: proc(g: ^Graph) {
	g.nodes = make([dynamic]Node)
	g.edges = make([dynamic]Edge)
	g.spring = 14
	g.rest = 150
	g.repulsion = 220_000
	g.damping = 3.5
	g.gravity = 1.2
	g.selected = -1
	g.linking = false
	reset(g)
}

shutdown_graph :: proc(g: ^Graph) {
	delete(g.nodes)
	delete(g.edges)
}

reset :: proc(g: ^Graph) {
	clear(&g.nodes)
	clear(&g.edges)
	g.next_id = 0
	g.selected = -1
	n :: 7
	for i in 0 ..< n {
		ang := f32(i) / n * math.TAU
		pos := [2]f32{math.cos(ang), math.sin(ang)} * 170
		id := add_node(g, pos)
		// A little tangential speed so the springs are obviously alive.
		g.nodes[i].vel = [2]f32{-math.sin(ang), math.cos(ang)} * 50
		if i > 0 {
			add_edge(g, id - 1, id)
		}
		_ = id
	}
	add_edge(g, 0, n - 1)
	add_edge(g, 0, 3)
}

add_node :: proc(g: ^Graph, pos: [2]f32) -> int {
	id := g.next_id
	g.next_id += 1
	append(&g.nodes, Node{id = id, pos = pos})
	return id
}

add_edge :: proc(g: ^Graph, a, b: int) -> bool {
	if a == b || find_node(g, a) < 0 || find_node(g, b) < 0 {
		return false
	}
	for e in g.edges {
		if (e.a == a && e.b == b) || (e.a == b && e.b == a) {
			return false
		}
	}
	append(&g.edges, Edge{a, b})
	return true
}

delete_node :: proc(g: ^Graph, id: int) {
	idx := find_node(g, id)
	if idx < 0 {
		return
	}
	ordered_remove(&g.nodes, idx)
	for i := len(g.edges) - 1; i >= 0; i -= 1 {
		e := g.edges[i]
		if e.a == id || e.b == id {
			ordered_remove(&g.edges, i)
		}
	}
	if g.selected == id {
		g.selected = -1
	}
}

find_node :: proc(g: ^Graph, id: int) -> int {
	for n, i in g.nodes {
		if n.id == id {
			return i
		}
	}
	return -1
}

node_at :: proc(g: ^Graph, p: [2]f32) -> int {
	best := -1
	best_d := NODE_R * NODE_R
	for n in g.nodes {
		d := p - n.pos
		dist2 := d.x * d.x + d.y * d.y
		if dist2 <= best_d {
			best = n.id
			best_d = dist2
		}
	}
	return best
}

// A few Euler substeps. Mass is 1. Damping is exponential so the rate does
// not depend on the frame time.
step :: proc(g: ^Graph, dt: f32) {
	if g.paused || len(g.nodes) == 0 {
		return
	}
	h := math.min(dt, 1.0 / 30.0)
	sub := 4
	sh := h / f32(sub)
	for _ in 0 ..< sub {
		step_once(g, sh)
	}
}

@(private)
step_once :: proc(g: ^Graph, dt: f32) {
	n := len(g.nodes)
	force := make([][2]f32, n)
	defer delete(force)

	for i in 0 ..< n {
		for j in i + 1 ..< n {
			d := g.nodes[j].pos - g.nodes[i].pos
			dist2 := d.x * d.x + d.y * d.y + SOFT * SOFT
			dist := math.sqrt(dist2)
			mag := g.repulsion / dist2
			dir := d / dist
			force[i] -= dir * mag
			force[j] += dir * mag
		}
	}

	for e in g.edges {
		ia := find_node(g, e.a)
		ib := find_node(g, e.b)
		if ia < 0 || ib < 0 {
			continue
		}
		d := g.nodes[ib].pos - g.nodes[ia].pos
		dist := math.sqrt(d.x * d.x + d.y * d.y)
		if dist < 0.001 {
			continue
		}
		dir := d / dist
		mag := g.spring * (dist - g.rest)
		force[ia] += dir * mag
		force[ib] -= dir * mag
	}

	decay := math.exp(-g.damping * dt)
	max_speed :: f32(1400)
	for i in 0 ..< n {
		force[i] -= g.nodes[i].pos * g.gravity
		g.nodes[i].vel = (g.nodes[i].vel + force[i] * dt) * decay
		sp := math.sqrt(g.nodes[i].vel.x * g.nodes[i].vel.x + g.nodes[i].vel.y * g.nodes[i].vel.y)
		if sp > max_speed {
			g.nodes[i].vel *= max_speed / sp
		}
		g.nodes[i].pos += g.nodes[i].vel * dt
	}
}

// Place a new node near the origin, or near the selection, and connect it
// when something is selected. Returns the new id.
sprout :: proc(g: ^Graph) -> int {
	pos := [2]f32{rand.float32_range(-40, 40), rand.float32_range(-40, 40)}
	if idx := find_node(g, g.selected); idx >= 0 {
		pos = g.nodes[idx].pos + {rand.float32_range(-30, 30), rand.float32_range(40, 80)}
	}
	id := add_node(g, pos)
	if g.selected >= 0 {
		add_edge(g, g.selected, id)
	}
	g.selected = id
	return id
}
