# odin-ui-v2

Clay layout, raylib drawing, one window loop. Raylib comes from the Odin compiler (`vendor:raylib`, 6.0). Clay is the bindings and static lib from [nicbarker/clay](https://github.com/nicbarker/clay) `e6cc369`.

The first app is a force-directed graph: nodes repel, edges are springs, a weak pull keeps the cloud on the canvas. The panel is there to drive the model.

```bash
./run.sh
```

Drag a node. **Link** then click another node to tie it to the selection. **N** adds a node, **delete** removes the selection, **space** pauses, **F** is fullscreen, **esc** quits. **F3** hides the timing strip.

## macOS

Raylib on its own misses fast trackpad clicks, blurs fullscreen on Retina, and does not lock to ProMotion. This package patches those without forking raylib:

- An `NSEvent` monitor records every mouse and key edge, then hands the event to GLFW unchanged. Raylib compares key state between polls, so a tap that starts and ends inside one frame never reads as pressed; the monitor keeps it.
- Fullscreen is `[NSWindow toggleFullScreen:]`, so the 2x backing store stays. `ToggleFullscreen` is the path that drops the scale to 1x.
- Swap interval stays off. The window view's display link (`NSView.displayLink`, macOS 14+) runs on its own thread; each tick bumps a counter and signals a semaphore, and the frame blocks until the counter has moved. `target_fps` 0 follows the display. A lower cap waits N ticks (60 on a 120 Hz panel is every second tick). The graph asks for 60.
- Input is polled after the wait, not right after the swap, so a frame draws input that is ~1 ms old instead of a frame old. On macOS `end_draw` swaps with `SwapScreenBuffer` instead of `EndDrawing`, which would poll a second time and eat raylib's key-press edges.
- Fullscreen on an adaptive-refresh screen (ProMotion, adaptive sync) runs on a fixed deadline grid instead. The panel scans out directly and refreshes when a frame lands, which made `CVDisplayLink` report our own presents back (ticks 2–11 ms apart). The frame wakes just early enough for its recent peak work, polls, draws, flushes, sleeps to the deadline with `mach_wait_until`, then swaps. The thread is time-constrained in that mode; without it the wake is ~1 ms late and jittery. Swap-to-swap spread at 60 went from ~10 ms to 0.03 ms. Before macOS 14 there is no view link and the grid is the clock everywhere.

Glyphs are rasterized at `fontSize * dpi` and drawn with bilinear filtering and no mipmaps, snapped to the physical pixel grid. Trilinear filtering is what softens raylib text. The atlas holds ASCII, Latin-1, and common UI punctuation and symbols; a codepoint the font file lacks draws as `?`.

UI fills are rlgl triangles on a 1×1 white texture, which is also raylib's shapes texture, with rounded corners as triangle fans. Plain `DrawRectangle` and friends work too; rlgl turns quads into triangles on this GL 4.1 context.

## Layout

```
ui/            Clay widgets, the frame loop, the raylib renderer, macOS hooks
app/           the graph
deps/clay/     Clay bindings + built static libs
fonts/
```

The app owns the loop (`ui.init`, `for ui.frame()`, `ui.shutdown`). Widgets read an input snapshot and emit Clay. They do not call raylib. The graph does, in the canvas region, before `ui.render` paints the panel on top.

## License

MIT, see [LICENSE](LICENSE). Bundled third-party pieces keep their own licenses: Clay is zlib ([deps/clay/LICENSE.md](deps/clay/LICENSE.md)), and the [Inter](https://github.com/rsms/inter) font is SIL OFL 1.1 ([fonts/Inter-LICENSE.txt](fonts/Inter-LICENSE.txt)). Raylib ships with the Odin compiler under zlib.
