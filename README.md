# odin-ui-v2

Clay layout, raylib drawing, one window loop. Raylib comes from the Odin compiler (`vendor:raylib`, 6.0). Clay is the bindings and static lib from [nicbarker/clay](https://github.com/nicbarker/clay) `e6cc369`.

The first app is a force-directed graph: nodes repel, edges are springs, a weak pull keeps the cloud on the canvas. The panel is there to drive the model.

```bash
./run.sh
```

Drag a node. **Link** then click another node to tie it to the selection. **N** adds a node, **delete** removes the selection, **space** pauses, **F** is fullscreen, **esc** quits. **F3** hides the timing strip.

## macOS

Raylib on its own misses fast trackpad clicks, blurs fullscreen on Retina, and does not lock to ProMotion. This package patches those without forking raylib:

- An `NSEvent` monitor records every mouse edge, then hands the event to GLFW unchanged.
- Fullscreen is `[NSWindow toggleFullScreen:]`, so the 2x backing store stays. `ToggleFullscreen` is the path that drops the scale to 1x.
- Swap interval stays off. A `CVDisplayLink` counts vblanks; the frame waits until that counter has moved, and skips the wait when a fullscreen present already blocked through one. `target_fps` 0 follows the display. A lower cap waits N ticks (60 on a 120 Hz panel is every second tick).

Glyphs are rasterized at `fontSize * dpi` and drawn with bilinear filtering and no mipmaps, snapped to the physical pixel grid. Trilinear filtering is what softens raylib text.

Filled rectangles from `DrawRectangle` are quads, and this GL 4.1 context does not rasterize them. UI fills are triangles that sample a 1×1 white texture, which is also what makes `DrawRectangle` look empty if you call it yourself after the font atlas is bound. Circles and lines are unaffected.

## Layout

```
ui/            Clay widgets, the frame loop, the raylib renderer, macOS hooks
app/           the graph
deps/clay/     Clay bindings + built static libs
fonts/
```

The app owns the loop (`ui.init`, `for ui.frame()`, `ui.shutdown`). Widgets read an input snapshot and emit Clay. They do not call raylib. The graph does, in the canvas region, before `ui.render` paints the panel on top.
